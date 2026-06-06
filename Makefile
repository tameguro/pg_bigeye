MODULE_big = pg_bigeye
OBJS = pg_bigeye.o audit_writer.o audit_format.o
PGFILEDESC = "pg_bigeye - audit log extension for PostgreSQL"

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_bigeye
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
