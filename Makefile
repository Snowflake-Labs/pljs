.PHONY: lintcheck format cleansql docs clean test all

PLJS_VERSION = 1.0.5

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
INCLUDEDIR := ${shell $(PG_CONFIG) --includedir}
INCLUDEDIR_SERVER := ${shell $(PG_CONFIG) --includedir-server}


CP = cp
SRCS = src/pljs.c src/cache.c src/functions.c src/types.c src/params.c
OBJS = src/pljs.o src/cache.o src/functions.o src/types.o src/params.o
MODULE_big = pljs
EXTENSION = pljs
DATA = pljs.control pljs--$(PLJS_VERSION).sql
PG_CFLAGS += -fPIC -Wall -Wextra -Wno-unused-parameter -Wno-declaration-after-statement \
    -Wno-cast-function-type -std=c11 -DPLJS_VERSION=\"$(PLJS_VERSION)\" -DEXPOSE_GC
SHLIB_LINK = -Ldeps/quickjs -lquickjs

ifeq ($(DEBUG), 1)
PG_CFLAGS += -g
SHLIB_LINK += -g
endif

ifeq ($(DEBUG_MEMORY), 1)
PG_CFLAGS += -fno-omit-frame-pointer -fsanitize=address
SHLIB_LINK += -fsanitize=address
endif

ifneq ($(DISABLE_DIRECT_JSONB_CONVERSION), 1)
PG_CFLAGS += -DJSONB_DIRECT_CONVERSION
endif

ifeq ($(EXPOSE_GC), 1)
PG_CFLAGS += -DEXPOSE_GC
endif

REGRESS = init-extension function json jsonb json_conv types bytea context \
	cursor array_spread plv8_regressions memory_limits inline composites \
	trigger procedure find_function start_proc window regressions \
	pg_name_bind pg_flush_error_state pg_spi_freetuptable \
	pg_null_bind \
	pg_execute_params_nulls pg_return_null_fcinfo \
	pg_prepared_plan_lifetime pg_bigint_lsn pg_bool_coercion pg_rich_types \
	pg_nested_error_envelope pg_plv8_port pg_subxact_isolation \
	pg_cdc_int8_boundary pg_cdc_text pg_cdc_bool pg_cdc_jsonb pg_cdc_uuid \
	pg_cdc_null_matrix currentresource pg_prepared_statements pg_datetime \
	pg_type_conversions_extra pg_record_setof pg_error_surface \
	pg_json_undefined pg_bigint_semantics pg_es6 pg_dropped_column \
	pg_spi_utility pg_typedarray_views \
	pg_find_function_no_perm pg_cursor_error_recovery pg_prepared_plan_gc \
	pg_cancellation pg_stack_depth pg_memory_limit_set \
	pg_conversion_footguns pg_type_matrix pg_null_edge_matrix \
	pg_memory_growth pg_cache_invalidation pg_param_plan_leak \
	pg_object_keys_leak \
	pg_window_polymorphic pg_fallback_type_io \
	pg_jsonb_recursion pg_json_stringify_failure pg_jsonb_nonfinite pg_jsonb_date \
	pg_errordata_stack

all: deps/quickjs/quickjs.h deps/quickjs/libquickjs.a pljs--$(PLJS_VERSION).sql

include $(PGXS)

src/pljs.o: deps/quickjs/libquickjs.a

deps/quickjs/quickjs.h:
	mkdir -p deps
	git submodule update --init --recursive
	patch -p1 <patches/01-shared-lib-build
	patch -p1 <patches/02-unicode-conflict

deps/quickjs/libquickjs.a: deps/quickjs/quickjs.h
	cd deps/quickjs && make

format:
	clang-format -i $(SRCS) src/pljs.h

pljs--$(PLJS_VERSION).sql: pljs.sql
	$(CP) pljs.sql pljs--$(PLJS_VERSION).sql

lintcheck:
	clang-tidy $(SRCS) -- $(LINTFLAGS) -I$(INCLUDEDIR) -I$(INCLUDEDIR_SERVER) -I$(PWD) --std=c11

all: deps/quickjs/quickjs.h deps/quickjs/libquickjs.a pljs--$(PLJS_VERSION).sql

clean: cleansql

cleansql:
	$(RM) -f pljs--$(PLJS_VERSION).sql

docs:
	doxygen src/Doxyfile
