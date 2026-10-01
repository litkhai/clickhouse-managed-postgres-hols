-- Resolve the ClickHouse connection variables for sql/02-load-from-clickhouse.sql.
--
-- Included with  \ir _clickhouse-vars.sql  so the password never has to be
-- typed on the command line, where it would show up in `ps`.
--
-- Each variable is taken, in order, from
--   1. a -v value, if one was given   (psql -v ch_host=...)
--   2. the environment                (CH_HOST ... set in config.env)
--   3. a default                      (port, user and database only)
--
--   psql variable   environment    default
--   ch_host         CH_HOST        (none, required)
--   ch_port         CH_PORT        9440
--   ch_user         CH_USER        default
--   ch_pass         CH_PASSWORD    (none, required)
--   ch_db           CH_DATABASE    mpg_hols_vec
--
-- scripts/psql.sh passes the CH_* variables into the container by name only.
--
-- If ch_host or ch_pass is still unset this says so and \quit-s. Run on its own
-- that ends psql. Included from another file, \quit only ends this file, so the
-- includer must check :{?ch_vars_ok} afterwards (02-load does).

\if :{?ch_host}
\else
  \getenv ch_host CH_HOST
\endif
\if :{?ch_port}
\else
  \getenv ch_port CH_PORT
\endif
\if :{?ch_user}
\else
  \getenv ch_user CH_USER
\endif
\if :{?ch_pass}
\else
  \getenv ch_pass CH_PASSWORD
\endif
\if :{?ch_db}
\else
  \getenv ch_db CH_DATABASE
\endif

\if :{?ch_port}
\else
  \set ch_port 9440
\endif
\if :{?ch_user}
\else
  \set ch_user default
\endif
\if :{?ch_db}
\else
  \set ch_db mpg_hols_vec
\endif

\set ch_vars_ok on
\if :{?ch_host}
\else
  \echo 'ClickHouse host is not set. Set CH_HOST in config.env (or the environment),'
  \echo 'or pass -v ch_host=<service>.clickhouse.cloud'
  \unset ch_vars_ok
\endif
\if :{?ch_pass}
\else
  \echo 'ClickHouse password is not set. Set CH_PASSWORD in config.env (or the environment),'
  \echo 'or pass -v ch_pass=...  (that puts it in `ps`; prefer CH_PASSWORD)'
  \unset ch_vars_ok
\endif
\if :{?ch_vars_ok}
\else
  \echo 'Also read, optional: CH_PORT (default 9440), CH_USER (default), CH_DATABASE (default mpg_hols_vec)'
  \quit
\endif
