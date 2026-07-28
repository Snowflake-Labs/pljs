-- Composite argument/return and trigger on a table with a dropped column.
--
-- After ALTER TABLE ... DROP COLUMN the tuple descriptor keeps an attnum hole
-- (attisdropped). pljs must skip that slot when marshalling a composite arg or
-- NEW/OLD in a trigger. The mirror procedures run against user tables that are
-- routinely altered, so this robustness matters. Ported from plv8.
CREATE TABLE dc_t (a int, b int, c text);
ALTER TABLE dc_t DROP COLUMN b;

CREATE FUNCTION dc_fn(r dc_t) RETURNS dc_t LANGUAGE pljs AS $$
  r.a = r.a + 1;
  r.c = r.c + '_fn';
  return r;
$$;
INSERT INTO dc_t VALUES (1, 'x');
SELECT (dc_fn(t.*)).* FROM dc_t t;

CREATE FUNCTION dc_trg() RETURNS trigger LANGUAGE pljs AS $$
  NEW.c = NEW.c + '!';
  return NEW;
$$;
CREATE TRIGGER dc_bt BEFORE INSERT ON dc_t FOR EACH ROW EXECUTE FUNCTION dc_trg();
INSERT INTO dc_t VALUES (10, 'y');
SELECT * FROM dc_t ORDER BY a;

DROP FUNCTION dc_fn(dc_t);
DROP TABLE dc_t;
DROP FUNCTION dc_trg();
