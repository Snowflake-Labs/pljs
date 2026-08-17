-- The structured half of the error envelope: that a SQL error raised inside
-- pljs.execute() reaches JavaScript as an Error carrying message, detail, hint
-- and the SQLSTATE, and that those survive a try/catch.
--
-- The envelope work changed user-visible error *text* in seven expected files but
-- added no test of its own, so the part that a caller actually programs against
-- was uncovered.  Requested on the PR 2 review.
--
-- NB for tools/check-test-discrimination.sh: this test discriminates against an
-- earlier commit than the one that adds it.  The fields it asserts were introduced
-- by the commit that exposes the SQLSTATE as a string; the commit that ships this
-- file only extracts the shared reporting helper, which is behaviour-preserving by
-- design.  Reverting that refactor therefore cannot make this test fail, and the
-- sweep flags it unless told so here.
CREATE FUNCTION eenv_fields() RETURNS text AS $$
  try {
    pljs.execute('SELECT 1/0');
    return 'no error';
  } catch (e) {
    return 'message=' + (e.message || '(none)') +
           ' sqlstate=' + (e.sqlstate || '(none)') +
           ' sqlerrcode=' + (e.sqlerrcode || '(none)');
  }
$$ LANGUAGE pljs;

SELECT eenv_fields() AS division_by_zero;

-- detail and hint are carried across when the underlying error has them.
CREATE TABLE eenv_t (id int PRIMARY KEY);
INSERT INTO eenv_t VALUES (1);

CREATE FUNCTION eenv_detail() RETURNS text AS $$
  try {
    pljs.execute('INSERT INTO eenv_t VALUES (1)');
    return 'no error';
  } catch (e) {
    return 'sqlstate=' + e.sqlstate +
           ' has_detail=' + (e.detail ? 'yes' : 'no') +
           ' message_mentions_key=' + (/eenv_t_pkey/.test(e.message) ? 'yes' : 'no');
  }
$$ LANGUAGE pljs;

SELECT eenv_detail() AS unique_violation;

-- A specific SQLSTATE can be dispatched on, which is the point of exposing it.
CREATE FUNCTION eenv_dispatch() RETURNS text AS $$
  try {
    pljs.execute('INSERT INTO eenv_t VALUES (1)');
    return 'no error';
  } catch (e) {
    if (e.sqlstate === '23505') return 'caught unique_violation by sqlstate';
    return 'unexpected sqlstate: ' + e.sqlstate;
  }
$$ LANGUAGE pljs;

SELECT eenv_dispatch() AS dispatched;

-- A user-defined error keeps its own message rather than being flattened to
-- "execution error", including across a nested pljs.execute() boundary.
CREATE FUNCTION eenv_inner() RETURNS int AS $$
  throw new Error('[E123] inner failed');
$$ LANGUAGE pljs;

CREATE FUNCTION eenv_nested() RETURNS text AS $$
  try {
    pljs.execute('SELECT eenv_inner()');
    return 'no error';
  } catch (e) {
    return 'preserved=' + (e.message.indexOf('[E123]') >= 0 ? 'yes' : 'no') +
           ' message=' + e.message;
  }
$$ LANGUAGE pljs;

SELECT eenv_nested() AS nested_user_error;

-- An error with an empty message must not produce an error with no text: the
-- fallback is what pljs_ereport_js_error() guards, at every report site.
CREATE FUNCTION eenv_empty() RETURNS int AS $$
  throw new Error('');
$$ LANGUAGE pljs;

SELECT eenv_empty();

DROP FUNCTION eenv_fields, eenv_detail, eenv_dispatch, eenv_nested, eenv_inner, eenv_empty;
DROP TABLE eenv_t;
