#!/bin/bash

#we have to create all these symbolic links because we are using a version of postgresql from the postgresql repo for nominatim but mapnik/modtile needs the standard locations
ln -s /usr/pgsql-12/bin/pg_config /usr/bin/pg_config
ln -s /usr/gdal32/bin/ogr2ogr /usr/bin/ogr2ogr
ln -s /usr/pgsql-12/include/libpq-fe.h /usr/include/libpq-fe.h
 ln -s /usr/pgsql-12/include/postgres_ext.h /usr/include/postgres_ext.h
