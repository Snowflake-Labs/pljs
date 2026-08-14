#include "postgres.h"

#include "catalog/pg_type_d.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "parser/parse_coerce.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/palloc.h"
#include "utils/timestamp.h"
#include "utils/typcache.h"

#include "deps/quickjs/quickjs.h"

#include "pljs.h"

#include <math.h>
#include <string.h>
#include <time.h>

/*
 * Error handling helper macros for consistent error patterns.
 */
#define PLJS_THROW_IF_NULL(ptr, msg, ctx)                                      \
  do {                                                                         \
    if ((ptr) == NULL) {                                                       \
      return js_throw((msg), (ctx));                                           \
    }                                                                          \
  } while (0)

#define PLJS_THROW_TYPE_ERROR(expected, ctx)                                   \
  js_throw("expected " expected " type", (ctx))

// Helper functions that should really exist as part of quickjs.
static JSClassID JS_CLASS_OBJECT = 1;
static JSClassID JS_CLASS_STRING = 5;
static JSClassID JS_CLASS_DATE = 10;
static JSClassID JS_CLASS_ARRAY_BUFFER = 19;
static JSClassID JS_CLASS_SHARED_ARRAY_BUFFER = 20;
static JSClassID JS_CLASS_UINT8C_ARRAY = 21;
static JSClassID JS_CLASS_INT8_ARRAY = 22;
static JSClassID JS_CLASS_UINT8_ARRAY = 23;
static JSClassID JS_CLASS_INT16_ARRAY = 24;
static JSClassID JS_CLASS_UINT16_ARRAY = 25;
static JSClassID JS_CLASS_INT32_ARRAY = 26;
static JSClassID JS_CLASS_UINT32_ARRAY = 27;

/**
 * Struct containing the type information for a catch-all*/
// if given object is an array.
inline static bool Is_ArrayType(JSValueConst obj, JSClassID class_id) {
  return NULL != JS_GetOpaque(obj, class_id);
}

// if given object is array buffer.
inline static bool Is_ArrayBuffer(JSValueConst obj) {
  return NULL != JS_GetOpaque(obj, JS_CLASS_ARRAY_BUFFER);
}

// if given object is shared array buffer.
inline static bool Is_SharedArrayBuffer(JSValueConst obj) {
  return NULL != JS_GetOpaque(obj, JS_CLASS_SHARED_ARRAY_BUFFER);
}

// if this is an actual object of any sort.
inline static bool Is_Object(JSValueConst obj) {
  return NULL != JS_GetOpaque(obj, JS_CLASS_OBJECT);
}

// if given object is a Date.
//
// NB: this cannot use JS_GetOpaque().  A Date keeps its epoch in the object's
// `u.object_data` JSValue, which shares a union with `u.opaque`, so
// JS_GetOpaque() returns the *bit pattern of the stored double*.  For
// `new Date(0)` that pattern is all zeroes, so the old opaque-based test
// reported "not a Date" for exactly the Unix epoch: binding it to a
// date/timestamp column fell through to the string path (a silent NULL before
// the input-function fix, an "unrecognized time zone" error after it), and in a
// jsonb result it came out as `{}`.  JS_GetClassID() is a real brand check.
inline static bool Is_Date(JSValueConst obj) {
  return JS_GetClassID(obj) == JS_CLASS_DATE;
}

/**
 * @brief Whether a value is a plain JavaScript object -- `{...}` -- as opposed
 * to an Array, Date, ArrayBuffer, typed array or any other branded builtin.
 *
 * This is a real brand check (see the Is_Date note above): every builtin has
 * its own class id, so only a bare object literal / `new Object` matches.
 * Callers use it to tell a `{column: value}` row object apart from a value
 * that legitimately *is* an object-like datum (a Date for a timestamp, a typed
 * array for a bytea, an Array for an array type).
 */
bool pljs_jsvalue_is_plain_object(JSValueConst obj) {
  return JS_GetClassID(obj) == JS_CLASS_OBJECT;
}

#if JSONB_DIRECT_CONVERSION
static JSValue convert_jsonb(JsonbContainer *in, JSContext *ctx);
static JSValue get_jsonb_value(JsonbValue *scalarVal, JSContext *ctx);
static Jsonb *convert_object(JSValue object, JSContext *ctx);
#endif

/**
 * @brief Converts a Javascript epoch to a Datum.
 *
 * @param @c double Javascript epoch
 * @returns #Datum of type `DATEADT`
 */
static Datum pljs_convert_epoch_to_date(double epoch) {
  epoch -= (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE) * 86400000.0;

#ifdef HAVE_INT64_TIMESTAMP
  epoch = (epoch * 1000) / USECS_PER_DAY;
#else
  epoch = (epoch / 1000) / SECS_PER_DAY;
#endif
  PG_RETURN_DATEADT((DateADT)epoch);
}

/**
 * @brief Converts a Javascript epoch to a Datum.
 *
 * @param @c double Javascript epoch
 * @returns #Datum of a timestamptz
 */
static Datum pljs_convert_epoch_to_timestamptz(double epoch) {
  epoch -= (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE) * 86400000.0;

#ifdef HAVE_INT64_TIMESTAMP
  return Int64GetDatum((int64)epoch * 1000);
#else
  return Float8GetDatum(epoch / 1000.0);
#endif
}

/**
 * @brief Converts a `DateADT` Datum to a Javascript epoch.
 *
 * @param #Datum of type `DateADT`
 * @returns @c double Javascript epoch
 */
static double pljs_convert_date_to_epoch(DateADT date) {
  double epoch;

#ifdef HAVE_INT64_TIMESTAMP
  epoch = (double)date * USECS_PER_DAY / 1000.0;
#else
  epoch = (double)date * SECS_PER_DAY * 1000.0;
#endif

  return epoch + (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE) * 86400000.0;
}

/**
 * @brief Converts a `TimestampTz` Datum to a Javascript epoch.
 *
 * @param #Datum of type `TimestampTz`
 * @returns @c double Javascript epoch
 */
static double pljs_convert_timestamptz_to_epoch(TimestampTz tm) {
  double epoch;

#ifdef HAVE_INT64_TIMESTAMP
  epoch = (double)tm / 1000.0;
#else
  epoch = (double)tm * 1000.0;
#endif

  return epoch + (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE) * 86400000.0;
}

/**
 * @brief Makes a copy of a #text type from Postgres and returns a `cstring`.
 *
 * Takes the input of a Postgres `TEXT` field, allocates memory in the
 * current memory context, and returns a `\0` terminated copy of the string
 * that was stored.  It is up to the caller to free the memory allocated.
 *
 * @param what #text - string to duplicate
 * @returns @c char * copy of the text field
 */
static char *pljs_util_dup_pgtext(text *what) {
  size_t len = VARSIZE(what) - VARHDRSZ;
  char *dup = palloc(len + 1);

  memcpy(dup, VARDATA(what), len);
  dup[len] = 0;

  return dup;
}

/**
 * @brief Converts an SPI status into static text.
 */
static const char *pljs_util_spi_status_string(int status) {
  static char private_buf[1024];

  if (status > 0)
    return "OK";

  switch (status) {
  case SPI_ERROR_CONNECT:
    return "SPI_ERROR_CONNECT";
  case SPI_ERROR_COPY:
    return "SPI_ERROR_COPY";
  case SPI_ERROR_OPUNKNOWN:
    return "SPI_ERROR_OPUNKNOWN";
  case SPI_ERROR_UNCONNECTED:
  case SPI_ERROR_TRANSACTION:
    return "current transaction is aborted, "
           "commands ignored until end of transaction block";
  case SPI_ERROR_CURSOR:
    return "SPI_ERROR_CURSOR";
  case SPI_ERROR_ARGUMENT:
    return "SPI_ERROR_ARGUMENT";
  case SPI_ERROR_PARAM:
    return "SPI_ERROR_PARAM";
  case SPI_ERROR_NOATTRIBUTE:
    return "SPI_ERROR_NOATTRIBUTE";
  case SPI_ERROR_NOOUTFUNC:
    return "SPI_ERROR_NOOUTFUNC";
  case SPI_ERROR_TYPUNKNOWN:
    return "SPI_ERROR_TYPUNKNOWN";
  default:
    snprintf(private_buf, sizeof(private_buf), "SPI_ERROR: %d", status);
    return private_buf;
  }
}

/**
 * @brief Helper for getting the length of a Javascript array.
 *
 * @param obj JSValueConst - Javascript array to check the length of
 * @param ctx #JSContext - Javascript context to execute in
 * @returns @c uint32_t
 */
uint32_t pljs_js_array_length(JSValueConst obj, JSContext *ctx) {
  JSValue length = JS_GetPropertyStr(ctx, obj, "length");
  int32_t array_length_int;
  JS_ToInt32(ctx, &array_length_int, length);

  return array_length_int;
}

/**
 * @brief Converts an `Oid` into `pljs_type`.
 *
 * Takes an input of a pointer to `pljs_type` and an `Oid`,
 * and queries Postgres for enough information for type conversions
 * between Postgres and Javascript.
 *
 * @param type #pljs_type - the location to store the type data
 * @param typid #Oid - the Postgres type to decode
 */
void pljs_type_fill(pljs_type *type, Oid typid) {
  bool is_preferred;
  type->typid = typid;

  get_type_category_preferred(typid, &type->category, &is_preferred);

  type->is_composite = (type->category == TYPCATEGORY_COMPOSITE);

  get_typlenbyvalalign(typid, &type->length, &type->byval, &type->align);

  if (type->category == TYPCATEGORY_ARRAY) {
    Oid elemid = get_element_type(typid);

    if (elemid == InvalidOid) {
      ereport(ERROR,
              (errmsg("cannot determine element type of array: %u", typid)));
    }

    type->typid = elemid;
    type->is_composite = (TypeCategory(elemid) == TYPCATEGORY_COMPOSITE);
    get_typlenbyvalalign(type->typid, &type->length, &type->byval,
                         &type->align);
  } else if (type->category == TYPCATEGORY_PSEUDOTYPE) {
    type->is_composite = true;
  }
}

/**
 * @brief Helper to get or lookup a TupleDesc with consistent ownership
 * semantics.
 *
 * If a TupleDesc is provided, it is used directly and needs_release is set to
 * false. If NULL is provided, a TupleDesc is looked up from the type OID and
 * needs_release is set to true, indicating the caller must call
 * ReleaseTupleDesc when done.
 *
 * @param typid #Oid - the type OID to look up if provided is NULL
 * @param provided #TupleDesc - optional pre-existing TupleDesc to use
 * @param needs_release @c bool* - output indicating if caller must release
 * @returns #TupleDesc the tuple descriptor to use
 */
static TupleDesc pljs_get_tupdesc(Oid typid, TupleDesc provided,
                                  bool *needs_release) {
  if (provided != NULL) {
    *needs_release = false;
    return provided;
  }

  *needs_release = true;
  return lookup_rowtype_tupdesc(typid, -1);
}

/**
 * @brief Converts a #Datum for a Javascript object.
 *
 * Takes a #Datum and converts it to a Javascript object.  If there is
 * an error, throws a Javascript exception.
 *
 * @param type #pljs_type - type information of the #Datum
 * @param arg #Datum - value to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of the object or thrown exception in case of error
 */
JSValue pljs_datum_to_object(pljs_type *type, Datum arg, JSContext *ctx) {
  if (arg == 0) {
    return JS_UNDEFINED;
  }

  JSValue obj;

  HeapTupleHeader rec = DatumGetHeapTupleHeader(arg);
  Oid tupType;
  int32 tupTypmod;
  TupleDesc tupdesc = NULL;
  HeapTupleData tuple;

  PG_TRY();
  {
    /* Extract type info from the tuple itself. */
    tupType = HeapTupleHeaderGetTypeId(rec);
    tupTypmod = HeapTupleHeaderGetTypMod(rec);
    tupdesc = lookup_rowtype_tupdesc(tupType, tupTypmod);
  }
  PG_CATCH();
  {
    ErrorData *edata = CopyErrorData();
    JSValue error = js_throw_error_data(edata, ctx);
    FlushErrorState();
    FreeErrorData(edata);

    return error;
  }
  PG_END_TRY();

  obj = JS_NewObject(ctx);

  if (tupdesc) {
    for (int16 i = 0; i < tupdesc->natts; i++) {
      Datum datum;
      bool isnull = false;

      if (TupleDescAttr(tupdesc, i)->attisdropped) {
        continue;
      }

      char *colname = NameStr(TupleDescAttr(tupdesc, i)->attname);
      tuple.t_len = HeapTupleHeaderGetDatumLength(rec);
      ItemPointerSetInvalid(&(tuple.t_self));
      tuple.t_tableOid = InvalidOid;
      tuple.t_data = rec;

      datum = heap_getattr(&tuple, i + 1, tupdesc, &isnull);

      JS_SetPropertyStr(
          ctx, obj, colname,
          pljs_datum_to_jsvalue(TupleDescAttr(tupdesc, i)->atttypid, datum,
                                isnull, true, ctx));
    }

    ReleaseTupleDesc(tupdesc);
  }

  return obj;
}

/**
 * @brief Converts a Postgres array to a Javascript array.
 *
 * Takes a Postgres #Datum and type and converts it into a Javascript
 * array.  All properties are set, including array length.
 *
 * @param type #pljs_type - type information for the array
 * @param arg #Datum - Postgres array to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of the array
 */
JSValue pljs_datum_to_array(pljs_type *type, Datum arg, JSContext *ctx) {
  JSValue array = JS_NewArray(ctx);
  Datum *values;
  bool *nulls;
  int nelems;
  ArrayType *arr = DatumGetArrayTypeP(arg);

  /*
   * pljs represents SQL arrays as flat JS arrays.  deconstruct_array() would
   * happily flatten a multidimensional array into a single JS array, silently
   * discarding the dimensionality (e.g. {{1,2},{3,4}} -> [1,2,3,4]) so a
   * round-trip corrupts the value.  Reject multidimensional arrays with a clear
   * error rather than losing the shape.
   */
  if (ARR_NDIM(arr) > 1) {
    ereport(ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("cannot convert a multidimensional array to a JavaScript "
                    "array"),
             errdetail("pljs represents SQL arrays as one-dimensional JS "
                       "arrays.")));
  }

  deconstruct_array(arr, type->typid, type->length, type->byval, type->align,
                    &values, &nulls, &nelems);

  for (int i = 0; i < nelems; i++) {
    JSValue value =
        pljs_datum_to_jsvalue(type->typid, values[i], nulls[i], true, ctx);

    JS_SetPropertyUint32(ctx, array, i, value);
  }

  JSValue length = JS_NewInt32(ctx, nelems);
  JS_SetPropertyStr(ctx, array, "length", length);

  pfree(values);
  pfree(nulls);

  return array;
}

/**
 * @brief Fallback type conversion from @Datum to @JSValue.
 *
 * Reached for every type pljs has no explicit case for: `uuid`, `pg_lsn`,
 * `money`, `time`, `interval`, `inet`, enums, domains, and extension types.
 * Converts through the type's own output function, which is the only encoding
 * that is both lossless and reversible by pljs_jsvalue_to_datum_fallback().
 *
 * The previous implementation reinterpreted the datum's bytes directly, which
 * corrupted data in two ways:
 *
 *   - Pass-by-value types were truncated with JS_NewInt32(), so an 8-byte
 *     value lost its high half and came back as a negative int32:
 *     '16/B374D848'::pg_lsn read as -1284188088.
 *   - Varlena types were read via VARDATA()/VARSIZE_ANY_EXHDR() without
 *     detoasting, so a compressed or out-of-line value yielded its raw TOAST
 *     bytes: a 102400-character domain-over-text value arrived in JS as 1186
 *     characters of compressed garbage.
 *
 * @param arg #Datum - Postgres datum to convert
 * @param type #pljs_type - type of the datum
 * @param ctx #JSContext - Javascript context
 * @returns #JSValue conversion of the Datum
 */
static JSValue pljs_datum_to_jsvalue_fallback(Datum arg, pljs_type type,
                                              JSContext *ctx) {
  Oid typoutput;
  bool typisvarlena;
  char *str;
  JSValue ret;

  getTypeOutputInfo(type.typid, &typoutput, &typisvarlena);

  str = OidOutputFunctionCall(typoutput, arg);
  ret = JS_NewString(ctx, str);
  pfree(str);

  return ret;
}

/**
 * @brief Converts a Postgres #Datum to a Javascript value.
 *
 * Takes a Postgres #Datum and type and converts it into a Javascript
 * value.  If the type is an array or is composite, then call out to
 * the correct functions.
 *
 * @param argtype #Oid - type information for the type
 * @param arg #Datum - Postgres value to convert
 * @param is_null @c bool - whether the datum is null
 * @param expand_composite @c bool - whether to expand composite types to
 * objects
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of the value, or JS_NULL if null
 */
JSValue pljs_datum_to_jsvalue(Oid argtype, Datum arg, bool is_null,
                              bool expand_composite, JSContext *ctx) {
  // Handle null case explicitly
  if (is_null) {
    return JS_NULL;
  }

  JSValue return_result;
  char *str;

  pljs_type type;
  pljs_type_fill(&type, argtype);

  if (type.category == TYPCATEGORY_ARRAY) {
    return pljs_datum_to_array(&type, arg, ctx);
  }

  if (expand_composite && type.is_composite) {
    return pljs_datum_to_object(&type, arg, ctx);
  }

  switch (type.typid) {
  case OIDOID:
    return_result = JS_NewInt64(ctx, arg);
    break;

  case BOOLOID:
    return_result = JS_NewBool(ctx, DatumGetBool(arg));
    break;

  case INT2OID:
    return_result = JS_NewInt32(ctx, DatumGetInt16(arg));
    break;

  case INT4OID:
    return_result = JS_NewInt32(ctx, DatumGetInt32(arg));
    break;

  case INT8OID:
    return_result = JS_NewBigInt64(ctx, DatumGetInt64(arg));
    break;

  case FLOAT4OID:
    return_result = JS_NewFloat64(ctx, DatumGetFloat4(arg));
    break;

  case FLOAT8OID:
    return_result = JS_NewFloat64(ctx, DatumGetFloat8(arg));
    break;

  case NUMERICOID:
    return_result = JS_NewFloat64(
        ctx, DatumGetFloat8(DirectFunctionCall1(numeric_float8, arg)));
    break;

  case TEXTOID:
  case VARCHAROID:
  case BPCHAROID:
  case XMLOID:
    // Get a copy of the string.
    str = pljs_util_dup_pgtext(DatumGetTextP(arg));

    return_result = JS_NewString(ctx, str);

    // Free the memory allocated.
    pfree(str);
    break;

  case NAMEOID:
    return_result = JS_NewString(ctx, DatumGetName(arg)->data);
    break;

  case JSONOID:
    // Get a copy of the string.
    str = pljs_util_dup_pgtext(DatumGetTextP(arg));

    return_result = JS_ParseJSON(ctx, str, strlen(str), NULL);

    // free the memory allocated.
    pfree(str);
    break;

  case JSONBOID: {
#if JSONB_DIRECT_CONVERSION
    Jsonb *jsonb = (Jsonb *)PG_DETOAST_DATUM(arg);

    if (JB_ROOT_IS_SCALAR(jsonb)) {
      JsonbValue jb;
      JsonbExtractScalar(&jsonb->root, &jb);
      return_result = get_jsonb_value(&jb, ctx);
    } else {
      return_result = convert_jsonb(&jsonb->root, ctx);
    }
#else
    // Get the datum.
    Jsonb *jb = DatumGetJsonbP(arg);

    // Convert it to a string (takes some casting, but JsonbContainer is also
    // a varlena).
    str = JsonbToCString(NULL, (JsonbContainer *)VARDATA(jb), VARSIZE(jb));

    return_result = JS_ParseJSON(ctx, str, strlen(str), NULL);

    // Free the memory allocated.
    pfree(str);
#endif
    break;
  }

  case BYTEAOID: {
    /*
     * Surface bytea as a Uint8Array, not a string.
     *
     * JS_NewStringLen() decodes its input as UTF-8, so any byte sequence that is
     * not valid UTF-8 was replaced with U+FFFD and the original bytes were gone
     * for good -- not merely re-encoded.  decode('deadbeef','hex') arrived in
     * JavaScript as a *two* character string and wrote back as `deadefbfbd`, and
     * every 0xFF byte became efbfbd.  Any bytea that is not plain ASCII was
     * silently destroyed by a round-trip through JS.
     *
     * A Uint8Array carries the bytes exactly, indexes and has .length like the
     * string did, and is what plv8 hands back (so this also makes the port more
     * compatible, not less).  The JS -> bytea direction already accepts typed
     * arrays, so the value round-trips.
     */
    struct varlena *p = (struct varlena *)PG_DETOAST_DATUM_PACKED(arg);
    size_t len = VARSIZE_ANY_EXHDR(p);
    JSValue buffer =
        JS_NewArrayBufferCopy(ctx, (const uint8_t *)VARDATA_ANY(p), len);

    if (JS_IsException(buffer)) {
      if (p != (struct varlena *)DatumGetPointer(arg)) {
        pfree(p);
      }
      return buffer;
    }

    /*
     * Build the view with JS_NewTypedArray() rather than by fetching
     * `Uint8Array` off the global object and calling it.
     *
     * Contexts are cached per user id and reused for the whole session, so
     * reading the constructor from the global meant any function that did
     * `globalThis.Uint8Array = f` -- or a pljs.start_proc that did it once --
     * permanently redirected every later bytea conversion in that session
     * through arbitrary user code, inside the argument-marshalling path.
     * JS_NewTypedArray() goes straight to the intrinsic constructor, so there
     * is nothing for user code to intercept.
     *
     * NB: js_typed_array_constructor() reads argv[1] (byteOffset) and argv[2]
     * (length) *unconditionally*, without consulting argc.  Passing a
     * one-element argv therefore reads two elements past the array, and
     * whatever happens to be on the stack becomes the offset and length -- which
     * is why an earlier attempt at this produced a zero-length view and was
     * abandoned in favour of the global lookup.  Pass all three explicitly.
     */
    JSValueConst ta_args[3] = {buffer, JS_UNDEFINED, JS_UNDEFINED};

    return_result = JS_NewTypedArray(ctx, 3, ta_args, JS_TYPED_ARRAY_UINT8);

    JS_FreeValue(ctx, buffer);

    /*
     * A large bytea can exhaust pljs.memory_limit here.  The result was
     * previously handed back unchecked, so the exception JSValue was stored into
     * argv[] and passed to JS_Call() as if it were a value.
     */
    if (JS_IsException(return_result)) {
      if (p != (struct varlena *)DatumGetPointer(arg)) {
        pfree(p);
      }
      return return_result;
    }

    /* PG_DETOAST_DATUM_PACKED only allocates when it actually had to detoast. */
    if (p != (struct varlena *)DatumGetPointer(arg)) {
      pfree(p);
    }
    break;
  }

  case DATEOID:
    return_result =
        JS_NewDate(ctx, pljs_convert_date_to_epoch(DatumGetDateADT(arg)));
    break;
  case TIMESTAMPOID:
  case TIMESTAMPTZOID:
    return_result = JS_NewDate(
        ctx, pljs_convert_timestamptz_to_epoch(DatumGetTimestampTz(arg)));
    break;

  default:
    return_result = pljs_datum_to_jsvalue_fallback(arg, type, ctx);
  }

  return return_result;
}

/**
 * @brief Converts a Javascript array to a Postgres array.
 *
 * Takes a Javascript #JSValue of an array and type and converts
 * it into a Postgres array.
 *
 * @param type #pljs_type - type information for the array
 * @param val #JSValue - Javascript array to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @param fcinfo #FunctionCallInfo - needed to conversion back to a #Datum
 * @returns #Datum of the array
 */
Datum pljs_jsvalue_to_array(pljs_type *type, JSValue val, JSContext *ctx,
                            FunctionCallInfo fcinfo) {
  ArrayType *result;
  Datum *values;
  bool *nulls;
  int ndims[1];
  int lbs[] = {[0] = 1};

  int32_t array_length = pljs_js_array_length(val, ctx);

  values = (Datum *)palloc(sizeof(Datum) * array_length);
  nulls = (bool *)palloc(sizeof(bool) * array_length);

  memset(nulls, 0, sizeof(bool) * array_length);

  ndims[0] = array_length;

  for (int i = 0; i < array_length; i++) {
    JSValue elem = JS_GetPropertyUint32(ctx, val, i);

    /*
     * Treat both null and undefined elements as SQL NULL.  Crucially we must
     * NOT let an element conversion see the *function's* fcinfo: a null /
     * undefined (or otherwise NULL-producing) element would run
     * PG_RETURN_NULL(), which sets fcinfo->isnull and marks the whole array
     * result as SQL NULL -- e.g. [1, undefined, 4] used to collapse to a NULL
     * array instead of {1,NULL,4}.  Passing NULL fcinfo routes NULLs through
     * the per-element is_null out-parameter instead.
     */
    if (JS_IsNull(elem) || JS_IsUndefined(elem)) {
      nulls[i] = true;
      JS_FreeValue(ctx, elem);
    } else {
      values[i] =
          pljs_jsvalue_to_datum(type->typid, elem, &nulls[i], ctx, NULL);
      JS_FreeValue(ctx, elem);
    }
  }

  result = construct_md_array(values, nulls, 1, ndims, lbs, type->typid,
                              type->length, type->byval, type->align);
  pfree(values);
  pfree(nulls);

  return PointerGetDatum(result);
}

/**
 * @brief Determines whether a Javascript object contains all of the
 * column names.
 *
 * Takes a Javascript #JSValue object and the possible column names
 * and determines whether all of the column names are reflected in
 * the object.
 *
 * @param val #JSValue - Javascript object to check
 * @param ctx #JSContext - Javascript context to execute in
 * @oaram tupdesc #TupleDesc
 * @returns @c bool
 */
bool pljs_jsvalue_object_contains_all_column_names(JSValue val, JSContext *ctx,
                                                   TupleDesc tupdesc,
                                                   char **missing_colname,
                                                   char **provided_keys) {
  uint32_t object_keys_length = 0;
  JSPropertyEnum *tab;

  if (missing_colname != NULL) {
    *missing_colname = NULL;
  }

  if (provided_keys != NULL) {
    *provided_keys = NULL;
  }

  if (JS_GetOwnPropertyNames(ctx, &tab, &object_keys_length, val,
                             JS_GPN_STRING_MASK) < 0) {
    return false;
  }

  bool result = true;

  for (int16 c = 0; c < tupdesc->natts; c++) {
    if (TupleDescAttr(tupdesc, c)->attisdropped) {
      continue;
    }

    char *colname = NameStr(TupleDescAttr(tupdesc, c)->attname);

    // Check to see if the key exists in the object
    bool found = false;
    for (uint32_t object_key = 0; object_key < object_keys_length;
         object_key++) {
      const char *atom = JS_AtomToCString(ctx, tab[object_key].atom);

      if (atom != NULL && strcmp(colname, atom) == 0) {
        found = true;
        JS_FreeCString(ctx, atom);
        break;
      }

      JS_FreeCString(ctx, atom);
    }

    if (!found) {
      result = false;

      /*
       * Report which column is missing, and what the object did offer, so the
       * caller can raise something actionable.  The bare "field name / property
       * name mismatch" left the author to guess, and the usual cause is a case
       * difference: JavaScript property names are case sensitive while
       * PostgreSQL folds unquoted identifiers to lower case.
       */
      if (missing_colname != NULL) {
        *missing_colname = pstrdup(colname);
      }

      if (provided_keys != NULL) {
        StringInfoData keys;
        uint32_t listed = 0;

        /*
         * Cap the list.  An object with ten thousand properties would otherwise
         * produce a ten-thousand-name error message, which goes to the server
         * log as well as to the client.  Ten names plus the total is enough to
         * diagnose a typo, which is what this message is for.
         */
        const uint32_t max_listed = 10;

        initStringInfo(&keys);

        for (uint32_t object_key = 0; object_key < object_keys_length;
             object_key++) {
          const char *atom;

          if (listed >= max_listed) {
            appendStringInfo(&keys, ", ... (%u properties in total)",
                             object_keys_length);
            break;
          }

          atom = JS_AtomToCString(ctx, tab[object_key].atom);

          if (atom == NULL) {
            continue;
          }

          if (keys.len > 0) {
            appendStringInfoString(&keys, ", ");
          }

          appendStringInfoString(&keys, atom);
          JS_FreeCString(ctx, atom);
          listed++;
        }

        *provided_keys = keys.data;
      }

      break;
    }
  }

  /*
   * JS_GetOwnPropertyNames() returns a js_malloc'd table plus one owned atom
   * reference per entry; both must be released.  Otherwise every call -- e.g.
   * every RETURNS TABLE / SETOF composite return_next() -- leaks the table
   * (which counts against the QuickJS runtime memory limit) and an atom
   * reference per property, and neither is reclaimed until the backend exits.
   * A long-running backend therefore slowly exhausts pljs.memory_limit.
   */
  for (uint32_t i = 0; i < object_keys_length; i++) {
    JS_FreeAtom(ctx, tab[i].atom);
  }
  js_free(ctx, tab);

  return result;
}

/**
 * @brief Converts a composite Javascript object into an array of Datums.
 *
 * Takes a Javascript object and converts it into an array of Datums, setting
 * the null flag for each Datum if it is null.  Note that this function assumes
 * that `is_null` is allocated and initialized to `0` (`false`) for each
 * element.
 *
 * @param type #pljs_type - type information for the record (used if tupdesc is
 * NULL)
 * @param val #JSValue - the Javascript object to convert
 * @param is_null @c bool** - pointer to array of null flags for each element
 * @param tupdesc #TupleDesc - can be `NULL`, will be looked up from type if so
 * @param ctx #JSContext - Javascript context to execute in
 * @returns Array of #Datum of the Javascript object, or NULL if val is
 * null/undefined
 */
Datum *pljs_jsvalue_to_datums(pljs_type *type, JSValue val, bool **is_null,
                              TupleDesc tupdesc, JSContext *ctx) {
  // Check for null/undefined BEFORE any allocations to avoid memory leaks
  if (JS_IsNull(val) || JS_IsUndefined(val)) {
    return NULL;
  }

  // Get the tuple descriptor, looking it up if not provided
  bool cleanup_tupdesc;
  tupdesc = pljs_get_tupdesc(type ? type->typid : InvalidOid, tupdesc,
                             &cleanup_tupdesc);

  // Allocate the values array now that we have the tuple descriptor
  Datum *values = (Datum *)palloc(sizeof(Datum) * tupdesc->natts);

  for (int16 c = 0; c < tupdesc->natts; c++) {
    // If this is a dropped column, we can skip it, and set the null flag to
    // true.
    if (TupleDescAttr(tupdesc, c)->attisdropped) {
      (*is_null)[c] = true;
      continue;
    }

    // Retrieve the column name of each attribute that we are expecting, we
    // only care about named tuples.
    char *colname = NameStr(TupleDescAttr(tupdesc, c)->attname);

    JSValue o = JS_GetPropertyStr(ctx, val, colname);

    /*
     * JS_GetPropertyStr() returns an owned reference, so it has to be released
     * on every path out of this iteration -- including the null/undefined
     * short-circuit below.  Leaking it costs one QuickJS reference per column
     * per row, on every composite return and every return_next() of a row
     * object, which is the hottest allocation path in the extension.  Because
     * QuickJS runs on the libc allocator the loss is invisible to
     * pg_backend_memory_contexts; it counts against pljs.memory_limit and is
     * not returned until the backend exits.
     */
    if (JS_IsNull(o) || JS_IsUndefined(o)) {
      (*is_null)[c] = true;
      JS_FreeValue(ctx, o);
      continue;
    }

    // Set the value of each Datum, or set the `is_null` flag if it is
    // considered `NULL`.
    values[c] = pljs_jsvalue_to_datum(TupleDescAttr(tupdesc, c)->atttypid, o,
                                      &(*is_null)[c], ctx, NULL);

    JS_FreeValue(ctx, o);
  }

  if (cleanup_tupdesc) {
    ReleaseTupleDesc(tupdesc);
  }

  return values;
}

/**
 * @brief Converts a Javascript object into a Postgres record.
 *
 * Takes a Javascript object and converts it into a Postgres
 * record (composite Postgres type).
 *
 * @param type #pljs_type - type information for the record
 * @param val #JSValue - the Javascript object to convert
 * @param is_null @c bool - pointer to fill of whether the record is null
 * @param tupdesc #TupleDesc - can be `NULL`
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #Datum of the Postgres record
 */
Datum pljs_jsvalue_to_record(pljs_type *type, JSValue val, bool *is_null,
                             TupleDesc tupdesc, JSContext *ctx) {
  Datum result = 0;

  // If the value is null or undefined, we can simply set the record to null
  // and return a `NULL` Datum.  `is_null` is optional: pljs_call_function()
  // passes NULL for it on the RECORDOID path, so dereferencing it
  // unconditionally crashed the backend for a `RETURNS record` function that
  // returned null or undefined.
  if (JS_IsNull(val) || JS_IsUndefined(val)) {
    if (is_null) {
      *is_null = true;
    }
    return (Datum)0;
  }

  // Get the tuple descriptor, looking it up if not provided
  bool cleanup_tupdesc;
  tupdesc = pljs_get_tupdesc(type->typid, tupdesc, &cleanup_tupdesc);

  Datum *values = (Datum *)palloc0(sizeof(Datum) * tupdesc->natts);
  bool *nulls = (bool *)palloc0(sizeof(bool) * tupdesc->natts);

  for (int16 c = 0; c < tupdesc->natts; c++) {
    if (TupleDescAttr(tupdesc, c)->attisdropped) {
      nulls[c] = true;
      continue;
    }

    char *colname = NameStr(TupleDescAttr(tupdesc, c)->attname);

    JSValue o = JS_GetPropertyStr(ctx, val, colname);

    /* Owned reference: release it on both paths.  See pljs_jsvalue_to_datums(). */
    if (JS_IsNull(o) || JS_IsUndefined(o)) {
      nulls[c] = true;
      JS_FreeValue(ctx, o);
      continue;
    }

    values[c] = pljs_jsvalue_to_datum(TupleDescAttr(tupdesc, c)->atttypid, o,
                                      &nulls[c], ctx, NULL);

    JS_FreeValue(ctx, o);
  }

  // Form a Tuple from the values and nulls using the tuple descriptor
  // as the template for the tuple.
  result = HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls));

  pfree(nulls);
  pfree(values);

  if (cleanup_tupdesc) {
    ReleaseTupleDesc(tupdesc);
  }

  return result;
}

/**
 * @brief Fallback type conversion from @JSValue to @Datum.
 *
 * The mirror of pljs_datum_to_jsvalue_fallback(): stringify the JS value and
 * parse it with the target type's input function.  That makes the round trip
 * lossless for every type pljs has no explicit case for (uuid, pg_lsn, money,
 * time, interval, inet, enums, domains -- including domain constraint checks)
 * and turns unparseable input into a clear error instead of a silently
 * corrupted datum.
 *
 * The previous implementation memcpy'd the JS string's bytes over the type's
 * in-memory representation, which produced garbage for anything whose text
 * form is not its binary form, leaked the JS C-string on every call, and
 * silently truncated values longer than the type's fixed length.
 *
 * @param value #JSValue - Javascript to convert
 * @param is_null @c bool - pointer to fill of whether the value is null
 * @param type #pljs_type - type of the datum
 * @param ctx #JSContext - Javascript context
 * @param fcinfo #FunctionCallInfo - call info to report SQL NULL through, or
 *   NULL when converting a bind parameter (no FunctionCallInfo available)
 * @returns #Datum conversion of the JSValue
 */
static Datum pljs_jsvalue_to_datum_fallback(JSValue value, bool *is_null,
                                            pljs_type type, JSContext *ctx,
                                            FunctionCallInfo fcinfo) {
  Oid typinput, typioparam;
  size_t plen;
  const char *str;
  Datum ret;

  // Set whether the Datum is `NULL` or not.
  JSValue is_set_null_value = JS_GetPropertyStr(ctx, value, "is_null");
  bool explicit_null = JS_ToBool(ctx, is_set_null_value);

  JS_FreeValue(ctx, is_set_null_value);

  // If the value's property of `null` is set to `true`, we return an empty
  // Datum.  When a FunctionCallInfo is available it is the only channel
  // Postgres reads, so report the NULL there: the scalar return path in
  // pljs.c discards the *is_null out-parameter, and leaving fcinfo->isnull
  // false made Postgres treat (Datum) 0 as a real value -- a garbage result
  // for a by-value type and a NULL-pointer dereference for a by-reference one.
  if (explicit_null) {
    if (fcinfo) {
      PG_RETURN_NULL();
    }

    if (is_null) {
      *is_null = true;
    }

    return (Datum)0;
  }

  str = JS_ToCStringLen(ctx, &plen, value);

  if (str == NULL) {
    ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                    errmsg("could not convert JavaScript value to a string")));
  }

  if (memchr(str, '\0', plen) != NULL) {
    JS_FreeCString(ctx, str);
    ereport(ERROR, (errcode(ERRCODE_UNTRANSLATABLE_CHARACTER),
                    errmsg("null byte (\\u0000) is not allowed in a value of "
                           "type %s",
                           format_type_be(type.typid))));
  }

  getTypeInputInfo(type.typid, &typinput, &typioparam);

  PG_TRY();
  {
    ret = OidInputFunctionCall(typinput, (char *)str, typioparam, -1);
  }
  PG_CATCH();
  {
    /* Do not leak the QuickJS C-string when the input function rejects it. */
    JS_FreeCString(ctx, str);
    PG_RE_THROW();
  }
  PG_END_TRY();

  JS_FreeCString(ctx, str);

  return ret;
}

/**
 * @brief Converts a JavaScript string into a #Datum through the target type's
 * text input function.
 *
 * The input function parses the full decimal text exactly and raises on
 * malformed or out-of-range input.  This is the only correct way to turn a
 * *string* into a numeric datum: routing it through QuickJS's numeric coercion
 * (JS_ToInt32/JS_ToInt64/JS_ToFloat64) goes via an IEEE-754 double, which
 * silently loses precision above 2^53 -- "9223372036854775807" came out as
 * INT64_MIN, and "123456789012345678" (only ~1.2e17) came out two off.
 *
 * @param typid #Oid - target type
 * @param val #JSValue - the JavaScript string to parse
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #Datum parsed from the string
 */
static Datum pljs_string_to_datum_via_input(Oid typid, JSValueConst val,
                                            JSContext *ctx) {
  size_t plen;
  const char *str = JS_ToCStringLen(ctx, &plen, val);
  Oid typinput, typioparam;
  Datum ret;

  if (str == NULL) {
    ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                    errmsg("could not convert JavaScript value to a string")));
  }

  if (memchr(str, '\0', plen) != NULL) {
    JS_FreeCString(ctx, str);
    ereport(ERROR,
            (errcode(ERRCODE_UNTRANSLATABLE_CHARACTER),
             errmsg("null byte (\\u0000) is not allowed in a value of type %s",
                    format_type_be(typid))));
  }

  getTypeInputInfo(typid, &typinput, &typioparam);

  PG_TRY();
  {
    ret = OidInputFunctionCall(typinput, (char *)str, typioparam, -1);
  }
  PG_CATCH();
  {
    /* Do not leak the QuickJS C-string when the input function rejects it. */
    JS_FreeCString(ctx, str);
    PG_RE_THROW();
  }
  PG_END_TRY();

  JS_FreeCString(ctx, str);

  return ret;
}

/**
 * @brief Raises the standard out-of-range error for an integer target type.
 */
static void pljs_int_out_of_range(Oid typid) {
  ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
                  errmsg("value is out of range for type %s",
                         format_type_be(typid))));
}

/**
 * @brief Converts a JavaScript number to an integer, rejecting values the target
 * type cannot represent.
 *
 * QuickJS's JS_ToInt32/JS_ToInt64 wrap modulo the word size, so 2147483648
 * silently became -2147483648, 40000 became -25536 for a smallint, and NaN and
 * Infinity both became 0.  PostgreSQL raises "integer out of range" for the
 * equivalent cast, and silently storing a different number is the worst outcome
 * for a data pipeline, so range-check instead.
 *
 * Fractions keep truncating toward zero, which is the established JavaScript
 * conversion behaviour; only the range is newly enforced.
 *
 * @param min @c double - lowest representable value
 * @param max_exclusive @c double - one past the highest.  Taken as a double
 *   because (double) INT64_MAX rounds *up* to 2^63, so an integer comparison
 *   would wrongly accept 2^63 itself.
 */
static int64 pljs_number_to_int_checked(JSContext *ctx, JSValueConst val,
                                        double min, double max_exclusive,
                                        Oid typid) {
  double d;

  if (JS_ToFloat64(ctx, &d, val) < 0) {
    elog(ERROR, "could not convert JavaScript value to a number");
  }

  if (isnan(d)) {
    ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
                    errmsg("cannot convert NaN to type %s",
                           format_type_be(typid))));
  }

  if (isinf(d)) {
    ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
                    errmsg("cannot convert Infinity to type %s",
                           format_type_be(typid))));
  }

  d = trunc(d);

  if (d < min || d >= max_exclusive) {
    pljs_int_out_of_range(typid);
  }

  return (int64)d;
}

/**
 * @brief Converts a JavaScript BigInt to an int64, rejecting values that do not
 * fit.
 *
 * JS_ToBigInt64() truncates to the low 64 bits without reporting anything, so
 * 2n**70n arrived as 0.  Round-tripping the result through JS_NewBigInt64()
 * detects that silently discarded magnitude.
 */
static int64 pljs_bigint_to_int64_checked(JSContext *ctx, JSValueConst val,
                                          Oid typid) {
  int64_t v;
  JSValue back;
  bool same;

  if (JS_ToBigInt64(ctx, &v, val) < 0) {
    elog(ERROR, "could not convert JavaScript BigInt to an integer");
  }

  back = JS_NewBigInt64(ctx, v);
  same = JS_StrictEq(ctx, back, val);
  JS_FreeValue(ctx, back);

  if (!same) {
    pljs_int_out_of_range(typid);
  }

  return v;
}

/**
 * @brief Converts a Javascript value to a Postgres #Datum.
 *
 * Takes a Javascript value and converts it into a Postgres #Datum,
 * checking whether it is an array or record and converting it
 * properly.
 *
 * @param rettype #Oid - type information for the record
 * @param val #JSValue - the Javascript object to convert
 * @param is_null @c bool* - pointer to fill with whether the result is null
 * @param ctx #JSContext - Javascript context to execute in
 * @param fcinfo #FunctionCallInfo - optional, can be NULL
 * @returns #Datum of the Postgres value
 */
Datum pljs_jsvalue_to_datum(Oid rettype, JSValue val, bool *is_null,
                            JSContext *ctx, FunctionCallInfo fcinfo) {
  // Initialize is_null to false
  if (is_null) {
    *is_null = false;
  }

  pljs_type type;

  pljs_type_fill(&type, rettype);

  /*
   * Handle null/undefined first, for every target type.
   *
   * This must precede the array and composite dispatches below.  Both of those
   * report SQL NULL only through the `is_null` out-parameter (the array check
   * did not report it at all -- it raised), but the scalar return path in
   * pljs_call_function() discards that out-parameter, so fcinfo->isnull is the
   * only channel Postgres reads.  Doing the check here is what lets a NULL
   * result reach the caller correctly regardless of the target type:
   *
   *   - For a composite, dispatching first meant Postgres was handed
   *     (Datum) 0 as if it were a real tuple -> backend SIGSEGV.
   *   - For an array type, the TYPCATEGORY_ARRAY check below rejected
   *     null/undefined with "value is not an Array", so an array-typed result
   *     or bind parameter could not be NULL at all -- even though every other
   *     place that walks a value already treats null/undefined as NULL (the
   *     array element loop, pljs_jsvalue_to_datums(), and the composite column
   *     loop in pljs_jsvalue_to_record() all short-circuit it).  That blocked
   *     `pljs.execute(sql, [null])` against an array parameter outright.
   *
   * A non-null value of the wrong shape still raises: the array check below
   * only ever sees values that are neither null nor undefined, so returning a
   * number, string or plain object for an array type keeps failing loudly
   * instead of silently becoming NULL.
   */
  if (JS_IsNull(val) || JS_IsUndefined(val)) {
    if (fcinfo) {
      PG_RETURN_NULL();
    } else {
      if (is_null) {
        *is_null = true;
      }

      return (Datum) 0;
    }
  }

  /*
   * Decide "build a SQL array" vs "build a JSON array" on the SQL type, not on
   * type.typid: pljs_type_fill() has already rewritten type.typid to the
   * ELEMENT type for any array, so testing it against JSONOID/JSONBOID here
   * also caught jsonb[] and json[], whose element type *is* json/jsonb.  Those
   * fell through to the scalar json branch below, which stringified the whole
   * JavaScript array -- "[object Object],[object Object]" -- and handed it to
   * the json input function, so `RETURNS jsonb[]` failed outright for every
   * element shape (objects, scalars, strings, nested arrays).  On stock
   * upstream the same path read uninitialised memory as a type OID, reporting
   * "cache lookup failed for type 2139062143" (0x7F7F7F7F, the wiped-memory
   * pattern).
   *
   * A bare json/jsonb target still turns a JavaScript array into a JSON array,
   * which is what the original guard was for.
   */
  if (JS_IsArray(ctx, val) &&
      (type.category == TYPCATEGORY_ARRAY ||
       (type.typid != JSONOID && type.typid != JSONBOID))) {
    return pljs_jsvalue_to_array(&type, val, ctx, fcinfo);
  }

  if (type.category == TYPCATEGORY_ARRAY && !JS_IsArray(ctx, val)) {
    /*
     * A user handing a non-array to an array-typed column is a data-type
     * mistake, not an internal fault, so it must not report XX000: a client
     * dispatching on SQLSTATE cannot tell that apart from a bug in the PL.
     * format_type_be() names the type the value was expected to fit.
     */
    ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH),
                    errmsg("cannot convert JavaScript value to %s",
                           format_type_be(rettype)),
                    errdetail("An array type requires a JavaScript Array.")));
  }

  if (type.is_composite) {
    return pljs_jsvalue_to_record(&type, val, is_null, NULL, ctx);
  }

  switch (rettype) {
  case VOIDOID:
    PG_RETURN_VOID();
    break;

  case OIDOID: {
    int64_t in;
    JS_ToInt64(ctx, &in, val);

    PG_RETURN_OID(in);
    break;
  }

  case BOOLOID: {
    /*
     * A string is parsed by bool's input function, not coerced with JS_ToBool.
     *
     * JS_ToBool() reports every non-empty string as true, so "false", "f", "no"
     * and "0" all became true while "" became false -- the exact opposite of
     * what the text means.  plv8 routed a bool bind through the type's input
     * function, and this difference is what silently broke the snowflake_cdc
     * `needs_snapshot` flag on the port: it was written with
     * `needsSnapshot ? "true" : "false"`, so the flag was set true and never
     * cleared, and every change batch then skipped its rows.
     *
     * The input function accepts exactly what SQL accepts (true/false, t/f,
     * yes/no, on/off, 1/0, any case, surrounded by optional whitespace) and
     * raises on anything else instead of guessing.
     */
    if (JS_IsString(val)) {
      return pljs_string_to_datum_via_input(BOOLOID, val, ctx);
    }

    /*
     * An object-wrapped primitive is not JS_IsString(), so `new String("false")`
     * skipped the branch above and fell through to JS_ToBool() -- which reports
     * every object as true, reintroducing exactly the inversion this case exists
     * to prevent.  Unwrap it and take the string path.
     *
     * Only String objects are unwrapped: a general JS_ToString() here would also
     * stringify arbitrary objects and arrays, so `{}` would become the text
     * "[object Object]" and then raise from boolin, where JS_ToBool()'s
     * truthiness is at least the documented JavaScript behaviour for those.
     */
    if (JS_IsObject(val) && JS_GetClassID(val) == JS_CLASS_STRING) {
      JSValue unwrapped = JS_ToString(ctx, val);

      if (JS_IsException(unwrapped)) {
        return (Datum)0;
      }

      Datum d = pljs_string_to_datum_via_input(BOOLOID, unwrapped, ctx);

      JS_FreeValue(ctx, unwrapped);

      return d;
    }

    int8_t in = JS_ToBool(ctx, val);
    PG_RETURN_BOOL(in);
    break;
  }

  case INT2OID: {
    int64 v;

    /* A string carries exact decimal text; parse it, do not go via a double. */
    if (JS_IsString(val)) {
      return pljs_string_to_datum_via_input(INT2OID, val, ctx);
    }

    if (JS_IsBigInt(ctx, val)) {
      v = pljs_bigint_to_int64_checked(ctx, val, INT2OID);
    } else {
      v = pljs_number_to_int_checked(ctx, val, (double)PG_INT16_MIN,
                                     -(double)PG_INT16_MIN, INT2OID);
    }

    if (v < PG_INT16_MIN || v > PG_INT16_MAX) {
      pljs_int_out_of_range(INT2OID);
    }

    PG_RETURN_INT16((int16)v);
    break;
  }

  case INT4OID: {
    int64 v;

    if (JS_IsString(val)) {
      return pljs_string_to_datum_via_input(INT4OID, val, ctx);
    }

    if (JS_IsBigInt(ctx, val)) {
      v = pljs_bigint_to_int64_checked(ctx, val, INT4OID);
    } else {
      v = pljs_number_to_int_checked(ctx, val, (double)PG_INT32_MIN,
                                     -(double)PG_INT32_MIN, INT4OID);
    }

    if (v < PG_INT32_MIN || v > PG_INT32_MAX) {
      pljs_int_out_of_range(INT4OID);
    }

    PG_RETURN_INT32((int32)v);
    break;
  }

  case INT8OID: {
    int64 v;

    if (JS_IsString(val)) {
      return pljs_string_to_datum_via_input(INT8OID, val, ctx);
    }

    if (JS_IsBigInt(ctx, val)) {
      v = pljs_bigint_to_int64_checked(ctx, val, INT8OID);
    } else {
      /*
       * A plain Number reaches int8 through a double, which represents integers
       * exactly only up to 2^53.  Range-checking alone therefore still accepted
       * values it then silently altered.  Reject anything in range but beyond
       * exact representation, and point at the two ways to express it exactly.
       *
       * The range check runs first: a value beyond int64 entirely is better
       * described as out of range than as inexact, and that is also what the
       * bind path's callers match on.
       */
      double d;

      if (JS_ToFloat64(ctx, &d, val) < 0) {
        ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                        errmsg("could not convert JavaScript value to a "
                               "number")));
      }

      if (!isnan(d) && !isinf(d) && d >= (double)PG_INT64_MIN &&
          d < -(double)PG_INT64_MIN && fabs(d) > 9007199254740992.0) {
        ereport(ERROR,
                (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
                 errmsg("value cannot be represented exactly as type bigint"),
                 errdetail("JavaScript numbers are IEEE-754 doubles and are "
                           "exact only up to 2^53."),
                 errhint("Use a BigInt literal (e.g. 9007199254740993n) or a "
                         "string.")));
      }

      /*
       * -(double) PG_INT64_MIN is exactly 2^63, one past INT64_MAX, and is the
       * correct exclusive bound: (double) PG_INT64_MAX rounds up to the same
       * value, so comparing against it would accept 2^63 itself.
       */
      v = pljs_number_to_int_checked(ctx, val, (double)PG_INT64_MIN,
                                     -(double)PG_INT64_MIN, INT8OID);
    }

    PG_RETURN_INT64(v);
    break;
  }

  case FLOAT4OID: {
    double in;

    if (JS_IsString(val)) {
      return pljs_string_to_datum_via_input(FLOAT4OID, val, ctx);
    }

    if (JS_ToFloat64(ctx, &in, val) < 0) {
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg("could not convert JavaScript value to a number")));
    }

    /*
     * float4 is narrower than the double we just read, so an out-of-range value
     * silently became +-Infinity where PostgreSQL's own float8::float4 cast
     * raises "value out of range: overflow".  NaN and the infinities are
     * representable in float4 and pass through unchanged; only a finite double
     * too large to represent is rejected.
     */
    if (!isnan(in) && !isinf(in) && isinf((float4)in)) {
      ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
                      errmsg("value out of range: overflow"),
                      errdetail("Value %g cannot be represented as type real.",
                                in)));
    }

    PG_RETURN_FLOAT4((float4)in);
    break;
  }

  case FLOAT8OID: {
    double in;
    JS_ToFloat64(ctx, &in, val);

    PG_RETURN_FLOAT8(in);
    break;
  }

  case NUMERICOID: {
    /*
     * A string carries exact decimal text, including a scale a double cannot
     * represent, so parse it with numeric's input function rather than routing
     * it through float8: "12345678901234567890.123456789" came back as
     * 12345678901234600000.
     */
    if (JS_IsString(val)) {
      return pljs_string_to_datum_via_input(NUMERICOID, val, ctx);
    }

    if (JS_IsBigInt(ctx, val)) {
      // Convert the value to a string then convert it to NUMERIC.
      JSValue str = JS_ToString(ctx, val);

      const char *in = JS_ToCString(ctx, str);
      Datum ret;

      if (in == NULL) {
        JS_FreeValue(ctx, str);
        elog(ERROR, "could not convert JavaScript BigInt to a string");
      }

      ret = DirectFunctionCall3(numeric_in, (Datum)in,
                                ObjectIdGetDatum(InvalidOid),
                                Int32GetDatum((int32)-1));

      /* Both references were leaked on every BigInt -> numeric conversion. */
      JS_FreeCString(ctx, in);
      JS_FreeValue(ctx, str);

      return ret;
    } else {
      double in;

      JS_ToFloat64(ctx, &in, val);

      return DirectFunctionCall1(float8_numeric, Float8GetDatum((float8)in));
    }
    break;
  }

  case NAMEOID: {
    const char *str = JS_ToCString(ctx, val);
    Datum ret = DirectFunctionCall1(namein, CStringGetDatum(str));
    JS_FreeCString(ctx, str);
    return ret;
    break;
  }

  case TEXTOID:
  case VARCHAROID:
  case BPCHAROID:
  case XMLOID: {
    size_t plen;
    const char *str = JS_ToCStringLen(ctx, &plen, val);

    if (str == NULL) {
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                    errmsg("could not convert JavaScript value to a string")));
    }

    /*
     * A PostgreSQL text value cannot contain an embedded NUL.  CStringGetTextDatum
     * uses strlen(), which would silently truncate a JS string at its first
     * \u0000 -- turning "a\u0000b" into "a" and losing data without warning.
     * Detect the NUL and raise a clear error instead of corrupting the value.
     */
    if (memchr(str, '\0', plen) != NULL) {
      JS_FreeCString(ctx, str);
      ereport(ERROR,
              (errcode(ERRCODE_UNTRANSLATABLE_CHARACTER),
               errmsg("null byte (\\u0000) is not allowed in a text value")));
    }

    Datum ret = PointerGetDatum(cstring_to_text_with_len(str, plen));
    JS_FreeCString(ctx, str);

    return ret;
    break;
  }

  case JSONOID: {
    JSValueConst *argv = &val;
    JSValue js = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    size_t plen;
    const char *str = JS_ToCStringLen(ctx, &plen, js);

    /*
     * JS_JSONStringify() fails (returning an exception) for a value JSON
     * cannot represent -- a circular structure, a BigInt anywhere in the tree,
     * or a throwing toJSON()/getter.  JS_ToCStringLen() then yields NULL and
     * the old code handed that straight to CStringGetTextDatum(), whose
     * strlen(NULL) segfaulted the backend.  Report the JavaScript error
     * instead.
     */
    if (str == NULL) {
      JSValue exc = JS_GetException(ctx);
      const char *msg = JS_IsNull(exc) || JS_IsUndefined(exc)
                            ? NULL
                            : JS_ToCString(ctx, exc);
      char *detail = msg ? pstrdup(msg) : NULL;

      if (msg) {
        JS_FreeCString(ctx, msg);
      }
      JS_FreeValue(ctx, exc);
      JS_FreeValue(ctx, js);

      if (detail) {
        ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                        errmsg("could not convert JavaScript value to json"),
                        errdetail("%s", detail)));
      }

      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg("could not convert JavaScript value to json")));
    }

    // return it as a text datum of the exact stringified length.
    Datum ret = PointerGetDatum(cstring_to_text_with_len(str, plen));

    JS_FreeCString(ctx, str);
    JS_FreeValue(ctx, js);

    return ret;
    break;
  }

  case JSONBOID: {
    JSValueConst *argv = &val;
#if JSONB_DIRECT_CONVERSION
    {
      Jsonb *obj = convert_object(argv[0], ctx);
      PG_RETURN_JSONB_P(DatumGetJsonbP((unsigned long)obj));
    }
#else // JSONB_DIRECT_CONVERSION
    JSValue js = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);

    const char *str = JS_ToCString(ctx, js);

    // return it as a Datum, since there is no direct CStringGetJsonb exposed.
    Datum ret = (Datum)DatumGetJsonbP(
        DirectFunctionCall1(jsonb_in, (Datum)(char *)str));

    JS_FreeCString(ctx, str);
    JS_FreeValue(ctx, js);

    return ret;
#endif
    break;
  }

  case BYTEAOID: {
    size_t psize;
    size_t pbytes_per_element = 0;

    uint8_t *buffer;

    uint32_t length = pljs_js_array_length(val, ctx);

    if (Is_ArrayType(val, JS_CLASS_UINT8_ARRAY) ||
        Is_ArrayType(val, JS_CLASS_INT8_ARRAY)) {
      pbytes_per_element = 1;
      psize = pbytes_per_element * length;

      uint8_t *array_copy = palloc(pbytes_per_element * length);

      for (size_t i = 0; i < length; i++) {
        int32_t in;

        JSValue jsval = JS_GetPropertyUint32(ctx, val, i);
        JS_ToInt32(ctx, &in, jsval);
        array_copy[i] = (uint8_t)in;
      }

      buffer = palloc(VARHDRSZ + psize);

      SET_VARSIZE(buffer, psize + VARHDRSZ);
      memcpy(VARDATA(buffer), array_copy, psize);

      pfree(array_copy);

      return PointerGetDatum(buffer);
    } else if (Is_ArrayType(val, JS_CLASS_UINT16_ARRAY) ||
               Is_ArrayType(val, JS_CLASS_INT16_ARRAY)) {
      pbytes_per_element = 2;
      psize = pbytes_per_element * length;

      uint16_t *array_copy = palloc(pbytes_per_element * length);

      for (size_t i = 0; i < length; i++) {
        int32_t in;

        JSValue jsval = JS_GetPropertyUint32(ctx, val, i);
        JS_ToInt32(ctx, &in, jsval);
        array_copy[i] = (uint16_t)in;
      }

      buffer = palloc(VARHDRSZ + psize);

      SET_VARSIZE(buffer, psize + VARHDRSZ);
      memcpy(VARDATA(buffer), array_copy, psize);

      pfree(array_copy);

      return PointerGetDatum(buffer);
    } else if (Is_ArrayType(val, JS_CLASS_UINT32_ARRAY) ||
               Is_ArrayType(val, JS_CLASS_INT32_ARRAY)) {
      pbytes_per_element = 4;
      psize = pbytes_per_element * length;

      uint32_t *array_copy = palloc(pbytes_per_element * length);

      for (size_t i = 0; i < length; i++) {
        int32_t in;

        JSValue jsval = JS_GetPropertyUint32(ctx, val, i);
        JS_ToInt32(ctx, &in, jsval);
        array_copy[i] = (uint32_t)in;
      }

      buffer = palloc(VARHDRSZ + psize);

      SET_VARSIZE(buffer, psize + VARHDRSZ);
      memcpy(VARDATA(buffer), array_copy, psize);

      pfree(array_copy);

      return PointerGetDatum(buffer);

    } else if (Is_ArrayBuffer(val)) {
      uint8_t *array_copy = JS_GetArrayBuffer(ctx, &psize, val);

      buffer = palloc(VARHDRSZ + psize);

      SET_VARSIZE(buffer, psize + VARHDRSZ);
      memcpy(VARDATA(buffer), array_copy, psize);
      return PointerGetDatum(buffer);
    } else if (JS_IsString(val)) {
      size_t str_length;
      const char *str = JS_ToCStringLen(ctx, &str_length, val);

      buffer = palloc(str_length + VARHDRSZ);

      SET_VARSIZE(buffer, str_length + VARHDRSZ);
      memcpy(VARDATA(buffer), str, str_length);

      JS_FreeCString(ctx, str);

      return PointerGetDatum(buffer);
    } else {
      /*
       * The value is not a typed array, ArrayBuffer, or string, so we have no
       * meaningful byte representation for it.  Raise a clear error instead of
       * silently returning SQL NULL, which used to hide binding mistakes (e.g.
       * accidentally passing a number for a bytea parameter).
       */
      ereport(ERROR,
              (errcode(ERRCODE_DATATYPE_MISMATCH),
               errmsg("cannot convert JavaScript value to bytea"),
               errdetail("Expected a string, ArrayBuffer or typed array.")));
    }
  }

  case DATEOID:
  case TIMESTAMPOID:
  case TIMESTAMPTZOID:
    if (Is_Date(val)) {
      double in;
      JS_ToFloat64(ctx, &in, val);

      /*
       * An invalid JS Date (getTime() === NaN -- which is exactly what
       * 'infinity'::timestamptz reads back as) has no finite epoch.  Feeding
       * NaN through the arithmetic below produced a bogus finite value
       * (2000-01-01) and silently corrupted the data.  Bind SQL NULL instead.
       */
      if (isnan(in)) {
        if (fcinfo) {
          PG_RETURN_NULL();
        }
        if (is_null) {
          *is_null = true;
        }
        return (Datum)0;
      }

      if (rettype == DATEOID) {
        return pljs_convert_epoch_to_date(in);
      } else {
        return pljs_convert_epoch_to_timestamptz(in);
      }
    } else {
      /*
       * Not a JS Date object: bind through the type's text input function so a
       * valid date/timestamp *string* (e.g. "2020-01-02 03:04:05") is parsed
       * correctly instead of being silently coerced to NULL, and invalid input
       * raises a clear error rather than vanishing.
       */
      size_t plen;
      const char *str = JS_ToCStringLen(ctx, &plen, val);
      Oid typinput, typioparam;
      Datum ret;

      if (str == NULL) {
        ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                    errmsg("could not convert JavaScript value to a string")));
      }

      if (memchr(str, '\0', plen) != NULL) {
        JS_FreeCString(ctx, str);
        ereport(ERROR,
                (errcode(ERRCODE_UNTRANSLATABLE_CHARACTER),
                 errmsg("null byte (\\u0000) is not allowed in a date/time value")));
      }

      getTypeInputInfo(rettype, &typinput, &typioparam);
      ret = OidInputFunctionCall(typinput, (char *)str, typioparam, -1);
      JS_FreeCString(ctx, str);

      return ret;
    }
    break;

  default:
    return pljs_jsvalue_to_datum_fallback(val, is_null, type, ctx, fcinfo);
  }

  // shut up, compiler
  if (is_null) {
    *is_null = true;
  }

  if (fcinfo) {
    PG_RETURN_NULL();
  } else {
    PG_RETURN_VOID();
  }
}

/**
 * @brief Converts an array of Javascript values into a Javascript array.
 *
 * Takes an array Javascript values and converts it into a Javascript
 * array of values, starting at the index requested.
 *
 * @param array #JSValue - array of #JSValue values to convert
 * @param argc @c int - number of values to convert
 * @param start @c int - index to start the conversion
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue array of the results
 */
JSValue pljs_values_to_array(JSValue *array, int argc, int start,
                             JSContext *ctx) {
  JSValue ret = JS_NewArray(ctx);

  uint32_t current = 0;
  for (int i = start; i < argc; i++) {
    JS_SetPropertyUint32(ctx, ret, current, array[i]);
    current++;
  }

  return ret;
}

/**
 * @brief Converts a Postgres #HeapTuple to a Javascript value.
 *
 * @param tupledesc #TupleDesc
 * @param heap_tuple #HeapTuple - value to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of the tuple value passed
 */
JSValue pljs_tuple_to_jsvalue(TupleDesc tupledesc, HeapTuple heap_tuple,
                              JSContext *ctx) {
  JSValue obj = JS_NewObject(ctx);

  for (int i = 0; i < tupledesc->natts; i++) {
    FormData_pg_attribute *tuple_attrs = TupleDescAttr(tupledesc, i);
    if (tuple_attrs->attisdropped) {
      continue;
    }

    bool isnull;
    Datum datum = heap_getattr(heap_tuple, i + 1, tupledesc, &isnull);

    char *name = NameStr(tuple_attrs->attname);

    JS_SetPropertyStr(
        ctx, obj, name,
        pljs_datum_to_jsvalue(tuple_attrs->atttypid, datum, isnull, true, ctx));
  }

  return obj;
}

/**
 * @brief Converts a Postgres SPI result to a Javascript value.
 *
 * @param status @c int - SPI status to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of the SPI status
 */
JSValue pljs_spi_result_to_jsvalue(int status, JSContext *ctx) {
  JSValue result;

  if (status < 0) {
    return js_throw(pljs_util_spi_status_string(status), ctx);
  }

  switch (status) {
  case SPI_OK_UTILITY:
  case SPI_OK_REWRITTEN:
    if (SPI_tuptable == NULL) {
      result = JS_NewInt32(ctx, SPI_processed);
      break;
    }
    // will fallthrough here to the "SELECT" logic below

  case SPI_OK_SELECT:
  case SPI_OK_INSERT_RETURNING:
  case SPI_OK_DELETE_RETURNING:
  case SPI_OK_UPDATE_RETURNING: {
    int nrows = SPI_processed;
    TupleDesc tupdesc = SPI_tuptable->tupdesc;

    JSValue obj = JS_NewArray(ctx);

    for (int r = 0; r < nrows; r++) {
      JSValue value =
          pljs_tuple_to_jsvalue(tupdesc, SPI_tuptable->vals[r], ctx);

      JS_SetPropertyUint32(ctx, obj, r, value);
    }

    result = obj;
    break;
  }
  default:
    result = JS_NewInt32(ctx, SPI_processed);
    break;
  }

  return result;
}

#if JSONB_DIRECT_CONVERSION
/**
 * @brief Converts a #JsonbValue to a #JSValue.
 *
 * @param scalar_value #JsonbValue - value to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of the #JsonbValue
 */
static JSValue get_jsonb_value(JsonbValue *scalar_value, JSContext *ctx) {
  // If the value is `null` then we return `null`.
  if (scalar_value->type == jbvNull) {
    return JS_NULL;
  } else if (scalar_value->type == jbvString) {
    // A `String`.
    return JS_NewStringLen(ctx, scalar_value->val.string.val,
                           scalar_value->val.string.len);
  } else if (scalar_value->type == jbvNumeric) {
    // `Number`.
    return JS_NewFloat64(
        ctx, DatumGetFloat8(DirectFunctionCall1(
                 numeric_float8, PointerGetDatum(scalar_value->val.numeric))));
  } else if (scalar_value->type == jbvBool) {
    // `Bool`.
    return JS_NewBool(ctx, scalar_value->val.boolean);
  } else {
    elog(ERROR, "unknown jsonb scalar type");
    return JS_NULL;
  }
}

/**
 * @brief Iterates through a #JsonbIterator.
 *
 * Iterate through a `JSONB` object and creates the proper Javascript type
 * for each: `Number`, `String`, `Bool`, `Date`, `Array`, `Object`.  This
 * function is meant to be run recursively.
 *
 * @param it #JsonbIterator - `JSONB` iterator to iterate on
 * @param container #JSValue - parent container to store the value in
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of `JSONB` value
 */
static JSValue jsonb_iterate(JsonbIterator **it, JSValue container,
                             JSContext *ctx) {
  JsonbValue value;
  int32 count = 0;
  JsonbIteratorToken token;
  JSValue key;
  char *key_string = NULL;
  JSValue obj;

  // Get the next value from the `JSONB` object.
  token = JsonbIteratorNext(it, &value, false);

  // Iterate through the values until the end of the `JSONB` object.
  while (token != WJB_DONE) {
    switch (token) {
    // If it is a new Object, create one.
    case WJB_BEGIN_OBJECT:
      obj = JS_NewObject(ctx);

      // If our container is an `Array`, append the object.
      // Iterate through the `JSONB` array until we get to the end of the array.
      if (JS_IsArray(ctx, container)) {
        JS_SetPropertyUint32(ctx, container, count,
                             jsonb_iterate(it, obj, ctx));
        count++;
      } else {
        // Otherwise set the property of the `Object`.  We use the
        // #key_string that we previously stored from the `JSONB` object.
        // Iterate through the `JSONB` object until we get to the end of the
        // object.
        JS_SetPropertyStr(ctx, container, key_string,
                          jsonb_iterate(it, obj, ctx));
        JS_FreeCString(ctx, key_string);
        key_string = NULL;
      }
      break;

      // If we are done with the object, return the container.
    case WJB_END_OBJECT:
      return container;

      break;

      // Start of a new `Array`.
    case WJB_BEGIN_ARRAY:
      obj = JS_NewArray(ctx);
      if (JS_IsArray(ctx, container)) {
        JS_SetPropertyUint32(ctx, container, count,
                             jsonb_iterate(it, obj, ctx));
        count++;
      } else {
        JS_SetPropertyStr(ctx, container, key_string,
                          jsonb_iterate(it, obj, ctx));
        JS_FreeCString(ctx, key_string);
        key_string = NULL;
      }
      break;

      // End of the array, return the container.
    case WJB_END_ARRAY:
      return container;

      break;

      // Retrieve the key for an object and store it as `key_string`.
    case WJB_KEY:
      key = get_jsonb_value(&value, ctx);
      key_string = (char *)JS_ToCString(ctx, key);
      JS_FreeValue(ctx, key);

      break;

      // Retrieve the object value and set it using `key_string`.
    case WJB_VALUE:
      JS_SetPropertyStr(ctx, container, key_string,
                        get_jsonb_value(&value, ctx));
      JS_FreeCString(ctx, key_string);

      // Clear the `key_string` so it cannot be re-used.
      key_string = NULL;

      break;

      // Retrieve an array element and set it, then increment the count.
    case WJB_ELEM:
      JS_SetPropertyUint32(ctx, container, count, get_jsonb_value(&value, ctx));
      count++;
      break;

      // We are done, return the container.
    case WJB_DONE:
      return container;
      break;

    default:
      elog(ERROR, "unknown jsonb iterator value");
    }

    // Retrieve the next `JSONB` token for the loop.
    token = JsonbIteratorNext(it, &value, false);
  }

  return container;
}

/**
 * @brief Converts a #JsonbContainer to a Javascript value.
 *
 * Entry function for the `JSONB` iterator, sets up a container to
 * eventually be returned, then calls the iterator function to fill the
 * container.
 *
 * @param in #JsonbContainer - the `JSONB` object to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JSValue of the `JSONB` object
 */
static JSValue convert_jsonb(JsonbContainer *in, JSContext *ctx) {
  JsonbValue val;
  JsonbIterator *it = JsonbIteratorInit(in);
  JsonbIteratorToken token = JsonbIteratorNext(&it, &val, false);

  // `JSONB` objects always need to be an `Array` or `Object`.
  JSValue container;

  // If this is an array, then create an `Array`.
  if (token == WJB_BEGIN_ARRAY) {
    container = JS_NewArray(ctx);
  } else {
    // Otherwise it is an `Object` by default.
    container = JS_NewObject(ctx);
  }

  return jsonb_iterate(&it, container, ctx);
}

#if PG_VERSION_NUM >= 190000
typedef JsonbInState JsonbBuildState;
static JsonbValue *jsonb_push(JsonbBuildState *pstate, JsonbIteratorToken seq,
                              JsonbValue *jbval) {
  pushJsonbValue(pstate, seq, jbval);
  return pstate->result;
}
#else
typedef JsonbParseState *JsonbBuildState;
static JsonbValue *jsonb_push(JsonbBuildState *pstate, JsonbIteratorToken seq,
                              JsonbValue *jbval) {
  return pushJsonbValue(pstate, seq, jbval);
}
#endif

// Forward declarations of the conversion functions.
struct pljs_jsonb_state;
static JsonbValue *jsonb_object_from_object(JSValue object,
                                            JsonbBuildState *pstate,
                                            JSContext *ctx,
                                            struct pljs_jsonb_state *state);
static JsonbValue *jsonb_array_from_array(JSValue array,
                                          JsonbBuildState *pstate,
                                          JSContext *ctx,
                                          struct pljs_jsonb_state *state);

/*
 * Recursion guard for the JS -> jsonb conversion.
 *
 * jsonb_object_from_object() and jsonb_array_from_array() recurse into every
 * nested container with no bound and no record of what they have already
 * visited, so a cyclic graph recursed forever and overflowed the C stack --
 * SIGSEGV, taking the backend down.  That is reachable from ordinary JS: a
 * self-referencing object (`o.self = o`), a self-referencing array, or a bare
 * `function` value (whose `prototype.constructor` points back at the function).
 * Deep-but-acyclic nesting overflowed the stack the same way.
 *
 * `ancestors` holds the containers currently on the recursion stack; a value
 * that reappears there is part of a cycle.  Depth is capped independently so
 * the array itself stays small and acyclic input cannot exhaust the stack.
 * Note the QuickJS stack limit does not help here: this recursion happens in
 * pljs's own C frames, not in the interpreter.
 */
/*
 * Depth is bounded by check_stack_depth() rather than by a constant of our own.
 * PostgreSQL's own recursive jsonb walkers (jsonb_in,
 * transform_jsonb_string_values) do the same, so the limit honours
 * max_stack_depth and a DBA who raises it gets the deeper nesting they asked
 * for.  A fixed cap of 200 was both arbitrary and much tighter than what
 * JSON.stringify() or jsonb_in accept, so legitimate deeply-nested data failed
 * here while the non-binary json path succeeded.
 *
 * The ancestor set is therefore purely for cycle detection, and grows on demand
 * instead of being a fixed 1.6 kB stack array.  It is palloc'd in the caller's
 * conversion context, which convert_object() deletes on both the success and the
 * error path, so an ereport out of here does not leak it.
 */
struct pljs_jsonb_state {
  void **ancestors;
  int depth;
  int capacity;
};

/*
 * Push `value` onto the ancestor stack, raising if it is already there (a cycle)
 * or if we are running out of C stack.
 */
static void pljs_jsonb_enter(JSValueConst value,
                             struct pljs_jsonb_state *state) {
  void *ptr = JS_VALUE_GET_PTR(value);

  /*
   * The recursion is in pljs's own C frames, not in the interpreter, so the
   * QuickJS stack limit never sees it.
   */
  check_stack_depth();

  for (int i = 0; i < state->depth; i++) {
    if (state->ancestors[i] == ptr) {
      ereport(ERROR, (errcode(ERRCODE_INVALID_RECURSION),
                      errmsg("cannot convert a circular structure to jsonb")));
    }
  }

  if (state->depth >= state->capacity) {
    int newcap = state->capacity ? state->capacity * 2 : 32;

    if (state->ancestors == NULL) {
      state->ancestors = (void **) palloc(sizeof(void *) * newcap);
    } else {
      state->ancestors =
          (void **) repalloc(state->ancestors, sizeof(void *) * newcap);
    }

    state->capacity = newcap;
  }

  state->ancestors[state->depth++] = ptr;
}

static void pljs_jsonb_leave(struct pljs_jsonb_state *state) {
  Assert(state->depth > 0);
  state->depth--;
}

/*
 * Release a property-name table from JS_GetOwnPropertyNames(): the table itself
 * is js_malloc'd and every tab[i].atom is an owned reference.
 */
static void pljs_free_property_table(JSContext *ctx, JSPropertyEnum *tab,
                                     uint32_t len) {
  for (uint32_t i = 0; i < len; i++) {
    JS_FreeAtom(ctx, tab[i].atom);
  }

  js_free(ctx, tab);
}

/**
 * @brief Converts a Postgres time in milliseconds to a 8601 datetime string.
 *
 * @param millis @c double - Postgres time in milliseconds
 * @returns @c char * representation of the date and time, or NULL if the value
 * is outside the range gmtime() can represent
 */
static char *time_as_8601(double millis) {
  char tmp[64];
  struct tm *tm_info;
  double integral, fractional;
  time_t t;
  int ms;

  /*
   * Split into whole seconds and milliseconds.  modf() truncates toward zero,
   * so a pre-1970 (negative) epoch yields a negative fraction: the old code
   * fed that straight into "%03d", producing e.g. ".-500Z" -- four characters
   * where three were budgeted, overrunning the fixed palloc(25) buffer.  Floor
   * the division instead so the millisecond part is always in [0, 999].
   */
  fractional = modf(millis / 1000.0, &integral);
  if (fractional < 0) {
    fractional += 1.0;
    integral -= 1.0;
  }

  ms = (int)(fractional * 1000.0 + 0.5);
  if (ms > 999) {
    ms = 999;
  }

  t = (time_t)integral;
  tm_info = gmtime(&t);

  if (tm_info == NULL) {
    return NULL;
  }

  /*
   * "%Y" is not limited to four digits (JS Dates reach year 275760), and the
   * caller must not assume a fixed 24-character result either -- the old code
   * hardcoded a length of 24, which truncated a five-digit year.  Size the
   * buffer generously and let the caller use strlen().
   */
  if (strftime(tmp, sizeof(tmp), "%Y-%m-%dT%H:%M:%S", tm_info) == 0) {
    return NULL;
  }

  return psprintf("%s.%03dZ", tmp, ms);
}

/**
 * @brief Converts a #JSValue into a `JSONB` value.
 *
 * @param pstate #JsonbBuildState - current state of the `JSONB` parsing
 * @param value #JSValue - the value to convert
 * @param type #JsonbIteratorToken
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JsonbValue `JSONB` result from the conversion
 */
static JsonbValue *jsonb_from_value(JSValue value, JsonbBuildState *pstate,
                                    JsonbIteratorToken type, JSContext *ctx,
                                    const char *key) {
  JsonbValue val;

  // If the token type is a key, the only valid value is `jbvString`.
  if (type == WJB_KEY) {
    val.type = jbvString;
    size_t len = strlen(key);

    val.val.string.val = palloc(len);
    memcpy(val.val.string.val, key, len);
    val.val.string.len = len;

    JS_FreeCString(ctx, key);
  } else {
    // Otherwise make the conversion based on the #JSValue type.
    if (JS_IsBool(value)) {
      val.type = jbvBool;
      val.val.boolean = JS_ToBool(ctx, value);
    } else if (JS_IsNull(value)) {
      val.type = jbvNull;
    } else if (JS_IsUndefined(value)) {
      return NULL;
    } else if (JS_IsString(value)) {
      val.type = jbvString;
      size_t len;
      const char *v = JS_ToCStringLen(ctx, &len, value);

      val.val.string.val = palloc(len);
      memcpy(val.val.string.val, v, len);
      val.val.string.len = len;

      JS_FreeCString(ctx, v);
    } else if (JS_IsNumber(value)) {
      double in;

      JS_ToFloat64(ctx, &in, value);

      /*
       * jsonb has no representation for NaN or +/-Infinity, and neither does
       * JSON.  float8_numeric() happily produces a numeric 'NaN'/'Infinity',
       * which pushJsonbValue stores verbatim: the resulting datum rendered as
       * `{"v": NaN}` -- text that is not valid JSON, cannot be re-parsed by
       * jsonb_in, and breaks pg_dump/restore and every client JSON parser.
       * Emit JSON null, which is what JSON.stringify() (and therefore pljs's
       * own `json` conversion path) does for these values.
       */
      if (!isfinite(in)) {
        val.type = jbvNull;
      } else {
        val.val.numeric = DatumGetNumeric(
            DirectFunctionCall1(float8_numeric, Float8GetDatum((float8)in)));
        val.type = jbvNumeric;
      }
    } else if (Is_Date(value)) {
      double in;

      JS_ToFloat64(ctx, &in, value);

      if (isnan(in)) {
        val.type = jbvNull;
      } else {
        char *iso = time_as_8601(in);

        if (iso == NULL) {
          val.type = jbvNull;
        } else {
          val.val.string.val = iso;
          val.val.string.len = strlen(iso);
          val.type = jbvString;
        }
      }
    } else {
      val.type = jbvString;
      size_t len;
      const char *v = JS_ToCStringLen(ctx, &len, value);

      val.val.string.val = palloc(len);
      memcpy(val.val.string.val, v, len);
      val.val.string.len = len;

      JS_FreeCString(ctx, v);
    }
  }

  // Push the result into the parse_state.
  return jsonb_push(pstate, type, &val);
}

/**
 * @brief Converts a #JSValue `Array` to a #JsonbValue array.
 *
 * @param array #JSValue - `Array` to convert
 * @param pstate #JsonbBuildState - the parse state of the `JSONB` object
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JsonbValue of the `JSONB` array
 */
static JsonbValue *jsonb_array_from_array(JSValue array,
                                          JsonbBuildState *pstate,
                                          JSContext *ctx,
                                          struct pljs_jsonb_state *state) {
  pljs_jsonb_enter(array, state);

  // Push the beginning of the array into the parse state.
  JsonbValue *value = jsonb_push(pstate, WJB_BEGIN_ARRAY, NULL);

  // Get the length of the `Array`.
  int32_t array_length = pljs_js_array_length(array, ctx);

  // Iterate through the `Array`.
  for (int i = 0; i < array_length; i++) {
    // Get the current element.
    JSValue elem = JS_GetPropertyUint32(ctx, array, i);

    /*
     * Date and function are objects, so they must be classified before the
     * generic JS_IsObject() test below, which would otherwise enumerate their
     * properties: a Date has none, so every Date in a jsonb result silently
     * became `{}`, and a function recursed into its own prototype chain.
     * JSON.stringify() renders a Date as an ISO string and a function in an
     * array as null; match that.
     */
    if (Is_Date(elem)) {
      value = jsonb_from_value(elem, pstate, WJB_ELEM, ctx, NULL);
    } else if (JS_IsUndefined(elem) || JS_IsFunction(ctx, elem)) {
      /*
       * An undefined *element* is JSON null, not an omitted element.  Skipping
       * it shortened the array and shifted every later index:
       * `[1, undefined, 3]` became `[1,3]` with length 2, while
       * JSON.stringify() of the same value is `[1,null,3]`.  For a mirrored
       * payload that silently rewrites the data.
       *
       * Note this differs from an undefined object *value*, which JSON drops
       * along with its key (`{a: undefined}` is `{}`); that behaviour is
       * correct and unchanged, and is handled by jsonb_from_value().
       *
       * A function element is also JSON null, for the same reason
       * JSON.stringify() renders it that way -- and the two branches pushed
       * an identical jbvNull, so they are merged rather than left as two
       * copies for the next person to update only one of.
       */
      JsonbValue null_val = {.type = jbvNull};

      value = jsonb_push(pstate, WJB_ELEM, &null_val);
    } else if (JS_IsArray(ctx, elem)) {
      value = jsonb_array_from_array(elem, pstate, ctx, state);
    } else if (JS_IsObject(elem)) {
      value = jsonb_object_from_object(elem, pstate, ctx, state);
    } else {
      value = jsonb_from_value(elem, pstate, WJB_ELEM, ctx, NULL);
    }

    // Free up the element.
    JS_FreeValue(ctx, elem);
  }

  // Set the value to the end of the array.
  value = jsonb_push(pstate, WJB_END_ARRAY, NULL);

  pljs_jsonb_leave(state);

  return value;
}

/**
 * @brief Converts a #JSValue `Object` to a #JsonbValue object.
 *
 * @param object #JSValue - `Object` to convert
 * @param pstate #JsonbBuildState - the parse state of the `JSONB` object
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #JsonbValue of the `JSONB` object
 */
static JsonbValue *jsonb_object_from_object(JSValue object,
                                            JsonbBuildState *pstate,
                                            JSContext *ctx,
                                            struct pljs_jsonb_state *state) {
  pljs_jsonb_enter(object, state);

  // Push the beginning of the object intp the parse state.
  JsonbValue *value = jsonb_push(pstate, WJB_BEGIN_OBJECT, NULL);
  uint32_t object_keys_length = 0;
  JSPropertyEnum *tab;

  // Get the keys of the `Object`.
  if (JS_GetOwnPropertyNames(ctx, &tab, &object_keys_length, object,
                             JS_GPN_STRING_MASK) < 0) {
    ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR),
                    errmsg("could not enumerate JavaScript object properties")));
  }

  /*
   * From here to the free below this frame owns `tab` and every atom in it, and
   * anything we descend into can raise: a circular structure, exhausted C stack,
   * a failed conversion.  Those longjmp straight past this frame, and
   * convert_object()'s PG_CATCH can delete the PostgreSQL context but cannot
   * free QuickJS allocations -- so without this guard a function returning a
   * circular object leaked a table plus one atom reference per key, per nesting
   * level, on every call.  That turned a crash into a permanent QuickJS-heap
   * leak counted against pljs.memory_limit, which a retry loop over bad input
   * walks into "out of memory".
   */
  JSValue volatile current = JS_UNDEFINED;

  PG_TRY();
  {
    // Iterate through the `Object` keys.
    for (uint32_t object_key = 0; object_key < object_keys_length;
         object_key++) {
      // Get the value.
      JSValue o =
          JS_GetPropertyInternal(ctx, object, tab[object_key].atom, object, 0);

      current = o;

      /*
       * JSON.stringify() omits function-valued properties entirely; do the same.
       * Beyond matching JSON semantics this avoids descending into a function's
       * `prototype`, whose `constructor` points back at the function -- an
       * unbounded recursion that used to crash the backend.
       */
      if (JS_IsFunction(ctx, o)) {
        JS_FreeValue(ctx, o);
        current = JS_UNDEFINED;
        continue;
      }

      const char *key = JS_AtomToCString(ctx, tab[object_key].atom);

      value = jsonb_from_value(o, pstate, WJB_KEY, ctx, key);

      /*
       * Date before the generic object test: a Date has no own properties, so
       * the JS_IsObject() branch turned every Date in a jsonb result into `{}`
       * and the ISO-string conversion below was dead code.
       */
      if (Is_Date(o)) {
        value = jsonb_from_value(o, pstate, WJB_VALUE, ctx, NULL);
      } else if (JS_IsArray(ctx, o)) {
        // If the value is an `Array` the convert it.
        value = jsonb_array_from_array(o, pstate, ctx, state);
      } else if (JS_IsObject(o)) {
        // Or convert an `Object`.
        value = jsonb_object_from_object(o, pstate, ctx, state);
      } else {
        // Or anything else.
        value = jsonb_from_value(o, pstate, WJB_VALUE, ctx, NULL);
      }

      // Free up the memory.
      JS_FreeValue(ctx, o);
      current = JS_UNDEFINED;
    }
  }
  PG_CATCH();
  {
    JS_FreeValue(ctx, current);
    pljs_free_property_table(ctx, tab, object_keys_length);
    PG_RE_THROW();
  }
  PG_END_TRY();

  pljs_free_property_table(ctx, tab, object_keys_length);

  // Push that we are at the end of an object.
  value = jsonb_push(pstate, WJB_END_OBJECT, NULL);

  pljs_jsonb_leave(state);

  return value;
}

/**
 * @brief Converts a #JSValue `Object` to a #Jsonb value.
 *
 * @param object #JSValue - `Object` to convert
 * @param ctx #JSContext - Javascript context to execute in
 * @returns #Jsonb the converted `JSONB` value
 */
static Jsonb *convert_object(JSValue object, JSContext *ctx) {
  // Create a new memory context for conversion.
  MemoryContext oldcontext = CurrentMemoryContext;
  MemoryContext conversion_context;
  conversion_context = AllocSetContextCreate(
      CurrentMemoryContext, "JSONB Conversion Context", ALLOCSET_SMALL_SIZES);

  MemoryContextSwitchTo(conversion_context);

  JsonbBuildState parse_state = {0};
  JsonbValue *volatile value = NULL;
  struct pljs_jsonb_state state = {.ancestors = NULL, .depth = 0, .capacity = 0};

  /*
   * The conversion can now raise (circular structure, nesting limit, a numeric
   * that will not convert).  Restore the caller's memory context and drop the
   * conversion context on the way out so a rejected value does not leak a
   * context and leave CurrentMemoryContext pointing into freed memory.
   */
  PG_TRY();
  {
    // Check the type and get its value.
    if (JS_IsArray(ctx, object)) {
      value = jsonb_array_from_array(object, &parse_state, ctx, &state);
    } else if (Is_Date(object) || JS_IsFunction(ctx, object)) {
    /*
     * A top-level Date renders as its ISO string and a top-level function as
     * JSON null (JSON.stringify semantics); both must bypass the object branch,
     * which would produce `{}` for a Date and recurse into a function forever.
     */
    jsonb_push(&parse_state, WJB_BEGIN_ARRAY, NULL);
    if (JS_IsFunction(ctx, object)) {
      JsonbValue null_val = {.type = jbvNull};

      jsonb_push(&parse_state, WJB_ELEM, &null_val);
    } else {
      jsonb_from_value(object, &parse_state, WJB_ELEM, ctx, NULL);
    }
    value = jsonb_push(&parse_state, WJB_END_ARRAY, NULL);
    value->val.array.rawScalar = true;
  } else if (JS_IsObject(object)) {
    value = jsonb_object_from_object(object, &parse_state, ctx, &state);
  } else {
    jsonb_push(&parse_state, WJB_BEGIN_ARRAY, NULL);
    jsonb_from_value(object, &parse_state, WJB_ELEM, ctx, NULL);
    value = jsonb_push(&parse_state, WJB_END_ARRAY, NULL);
    value->val.array.rawScalar = true;
  }
  }
  PG_CATCH();
  {
    MemoryContextSwitchTo(oldcontext);
    MemoryContextDelete(conversion_context);
    PG_RE_THROW();
  }
  PG_END_TRY();

  // Switch back to our old #MemoryContext.
  MemoryContextSwitchTo(oldcontext);

  // Create the #Jsonb object to return.
  Jsonb *ret = JsonbValueToJsonb(value);

  // Delete the conversion #MemoryContext.
  MemoryContextDelete(conversion_context);

  return ret;
}
#endif
