# mnesia_pg
Postgres backend to Mnesia via mnesia_ext

This is a very raw implementation, made as proof of concept and for preliminary benchmarking. It has not been used in production. Feel free to improve it.

```
$ sudo -u postgres createuser --superuser mnesia
$ sudo -u postgres createdb mnesia
$ sudo -u postgres psql
postgres=# \password mnesia
postgres=# \q
```

```erlang
$ rebar3 shell --sname mpg
> application:ensure_all_started(pgsql).
> ok = mnesia:create_schema([node()], [{backend_types,
                                          [{pg_copies,
                                            mnesia_pg}]}]).
> ok = mnesia:start().
> application:ensure_all_started(mnesia_pg).
> mnesia:create_table(pg, [{pg_copies, [node()]},{record_name, x}]).
> mnesia:dirty_write(pg, {x, a, 1}).
> mnesia:dirty_read(pg, a).
[{x,a,1}]
```
