#!/bin/bash

NOM_USERNAME=nominatim
NOM_USERHOME=/data/nominatim
PY_PKGS="psycopg2 python-dotenv psutil Jinja2 PyICU"
PG_VER=12
PG_SERVICE=/usr/lib/systemd/system/postgresql-$PG_VER.service
PG_DATA=/data/pgdata
PG_CONF=$PG_DATA/postgresql.conf
NOM_VER=3.7.1
NOM_DL=https://nominatim.org/release/Nominatim-$NOM_VER.tar.bz2
OSM_DIR=$NOM_USERHOME/osm_import
THREAD_CT=$(nproc --all)
OSM_CACHE=$(free --mega | awk '{print $4}' | sed -n '2 p')
MAPNIK_USERNAME=mapnik
MAPNIK_USERHOME=/data/mapnik
TILE_DIR=/data/tiles

#these values reflect our first osm server which had 750GB ram and 30 core CPU
function pg_tuning(){
	CACHE_GB=$(free --giga |  awk '{print $4}' |sed -n '2 p')
	shared_buffer="$(echo "$CACHE_GB"*.4 | bc)"
	sed -i "s|.*shared_buffers.*|shared_buffers = $(shared_buffer)GB|" $PG_CONF
	sed -i "s|.*maintenance_work_mem.*|maintenance_work_mem = 100GB|" $PG_CONF
	sed -i "s|.*autovacuum_work_mem.*|autovacuum_work_mem = 2GB|" $PG_CONF
	sed -i "s|.*work_mem.*|work_mem = 5GB|" $PG_CONF
	sed -i "s|.*effective_cache_size.*|effective_cache_size = 200GB|" $PG_CONF
	sed -i "s|.*synchronous_commit.*|synchronous_commit = off|" $PG_CONF
	sed -i "s|.*checkpoint_segments.*|checkpoint_segments = 100|" $PG_CONF
	sed -i "s|.*checkpoint_timeout.*|checkpoint_timeout = 10min|" $PG_CONF
	sed -i "s|.*checkpoint_completion_target.*|checkpoint_completion_target = 0.9|" $PG_CONF
}

function init_pg(){
	mkdir $PGDATA
	chown postgres:postgres $PGDATA
	PGSETUP_INITDB_OPTIONS="-D ${PG_DATA}" /usr/pgsql-$PG_VER/bin/postgresql-$PG_VER-setup initdb
	sed -i "s|.*Environment=PGDATA=.*|Environment=PGDATA=$PG_DATA|" $PG_SERVICE
	systemctl daemon-reload
	systemctl enable postgresql-12
	pg_tuning
	systemctl restart postgresql-12
	cd $PGDATA
	sudo -u postgres createuser -s $NOM_USERNAME
	sudo -u postgres createuser apache
}

function create_nom_user(){
	useradd -d $NOM_USERHOME -s /bin/bash -m $NOM_USERNAME
	chmod a+x $NOM_USERHOME
}

function create_mapnik_user(){
	useradd -d $MAPNIK_USERHOME -s /bin/bash -m $MAPNIK_USERNAME
	chmod a+x $MAPNIK_USERHOME
}

function init_nom(){
	cd $NOM_USERHOME/build
	su $NOM_USERNAME
	wget $NOM_DL
	tar xf Nominatim-$NOM_VER.tar.bz2
	mkdir $NOM_USERHOME/build
	cd $NOM_USERHOME/build
	cmake $NOM_USERHOME/Nominatim-3.7.1
	make
	exit
	make install
	rm $NOM_USERHOME/Nominatim-$NOM_VER.tar.bz2
	setup_nom_website
}

function init_nom_website(){
	mkdir $NOM_USERHOME/nominatim-project
	cd $NOM_USERHOME/nominatim-project
	nominatim refresh --website
	systemctl enable httpd
    systemctl restart http
    sed -i "s|NOMUSERHOME|$NOM_USERHOME|" dist/config.defaults.js
    
    semanage fcontext -a -t httpd_sys_content_t "/usr/local/nominatim/lib/lib-php(/.*)?"
	semanage fcontext -a -t httpd_sys_content_t "$NOM_USERHOME/nominatim-project/website(/.*)?"
	semanage fcontext -a -t lib_t "$NOM_USERHOME/nominatim-project/module/nominatim.so"
	restorecon -R -v /usr/local/lib/nominatim
	restorecon -R -v $NOM_USERHOME/nominatim-project
	echo NOMINATIM_DATABASE_WEBUSER="apache" | tee .env
} 

function do_precond(){
	#multiple users will need pg_config so rather than modify path for each user, we create link to /usr/bin
	ln -s /usr/pgsql-12/bin/pg_config /usr/bin/pg_config
	#Now that python3 is installed we can install the py deps
	create_nom_user
	pip install --trusted-host files.pythonhosted.org  --trusted-host pypi.org psycopg2 python-dotenv psutil Jinja2 PyICU
}

function import_osm(){
	mkdir $OSM_DIR
	chown nominatim $OSM_DIR
	su - nominatim
	cd $OSM_DIR
	wget https://www.nominatim.org/data/wikimedia-importance.sql.gz
	wget https://www.nominatim.org/data/gb_postcode_data.sql.gz
	wget https://www.nominatim.org/data/us_postcode_data.sql.gz
	wget https://nominatim.org/data/tiger2020-nominatim-preprocessed.tar.gz
	wget https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf
	nominatim import -v -j $THREAD_CT --osm-file planet-latest.osm.pbf --osm2pgsql-cache $OSM_CACHE 2>&1 | tee setup.log
	nominatim special-phrases --import-from-wiki
	nominatim refresh -j $THREAD_CT --wiki-data --importance
	nominatim add-data --tiger-data tiger2020-nominatim-preprocessed.tar.gz
	echo NOMINATIM_USE_US_TIGER_DATA=yes >> .env
	nominatim refresh --functions
	nominatim index
}

function setup_postgres_modtile(){
	su postgres -i
	createuser $MAPNIK_USERNAME
	createdb -E UTF8 -O mapnik gis
	psql
	\c gis
	CREATE EXTENSION postgis;
	CREATE EXTENSION hstore;
	ALTER TABLE geometry_columns OWNER TO $MAPNIK_USERNAME
	ALTER TABLE spatial_ref_sys OWNER TO $MAPNIK_USERNAME
	\q
	exit
}

function build_mod_tile(){
	mkdir ~/src
	cd !$
	git clone git://github.com/openstreetmap/mod_tile.git
	cd mod_tile
	./autogen.sh
	./configure
	make
	exit
	cd $MAPNIK_USERNAME/mod_tile
	make install
	make install-mod_tile
}

function build_mapnik(){
	git clone https://github.com/mapnik/mapnik.git
	cd mapnik
	git submodule update --init
	#we have to tell mapnik where proj includes dir is because we are using proj from postgresql repo
	./configure PROJ_INCLUDES=/usr/proj72/include/
	JOBS=80 make
	make install
	ln -s /usr/local/lib/libmapnik.so.4.0 /usr/lib64/libmapnik.so.4.0
	
}

function import_gis(){
	npm install -g carto
	 ln -s /usr/proj72/lib/libproj.so.19.2.1 /usr/lib64/libproj.s
	su mapnik
	cd ~/src
	git clone git://github.com/gravitystorm/openstreetmap-carto.git
	cd  openstreetmap-carto
	carto project.mml > mapnik.xml
	mkdir data
	cd !$
	wget https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf
	osm2pgsql -d gis --create --slim  -G --hstore  -C 500000 --number-processes 75 -S ~/src/openstreetmap-carto/openstreetmap-carto.style ~/data/planet-latest.osm.pbf
	cd ~/src/openstreetmap-carto/
	psql -d gis -f indexes.sql
	sed -i "s|.*download = s.get(source.*|download = s.get(source["url"], headers=headers, verify=False)|" ~/src/openstreetmap-carto/scripts/get-external-data.py
	npm install ogr2ogr -g //need to sudo
	scripts/get-external-data.py
	mkdir $TILE_DIR
	sed -i "s|TILES_DIR|$TILE_DIR|" /etc/renderd.conf
	sed -i "s|XML_DIR|$MAPNIK_USERHOME/src/openstreetmap-carto/|" /etc/renderd.conf
	chown -R /
}

function setup_modtile(){
	create_modtile_user
	setup_postgres_modtile
	build_modtile
}

function setup_nom_ui(){
	npm install yarn -g
	a2enmod rewrite
	su - nominatim
	git clone https://github.com/osm-search/nominatim-ui
	cd nominatim-ui
	cp dist/config.defaults.js dist/config.js
	echo "//this file is looked for by the installation" > theme/config.theme.js
	sed -i "s|.*Nominatim_API_Endpoint.*|Nominatim_API_Endpoint: 'https://maps.shambaughefiles.net/nominatim/',|" dist/config.defaults.js
	sed -i "s|.*Page_Title:.*|Page_Title: 'Nominatim',|" dist/config.defaults.js
	yarn install
	yarn build
	su postgres
	psql
	GRANT SELECT ON ALL TABLES IN SCHEMA public to apache;
	\q
	exit
}

function show_help(){
	echo "Usage:$0 [options] (commands)"
	echo ""
    echo "	--help          	show this help message"
    echo ""
    echo "  Setup Commands:"
    echo "	--auto			Run default commands"
    echo "	--postgres		Install Postgresql $PG_VER"
    echo "	--nominatim		Build and install Nominatim"
    echo "	--website		Setup Apache to serve Nominiatim site. Implies --nominatim"	
    echo "	--import-nominatim	Import latest planet pbf into Postgresql for Nominatim. Implies --postgres and --nominatim"
    echo "	--mapnik		Build and install Mapnik"
    echo "	--import-gis		Import latest planet pbf into Postgresql for mod tile. Implies --postgres and --mapnik"
    echo "  --mod-tile		Configure renderd and apache to serve tiles. Implies --mapnik"
    echo ""
}
if [[ "$#" -eq 0 ]] ; then
    show_help
   	exit
fi


while [ -n "$1" ]; do
        case $1 in
        --help)
        	show_help
        	exit 0
        	;;
        --auto)
        	I_PG=Y
        	I_NOM=Y
        	I_SITE=Y
        	I_OSM=Y
        	I_MAPNIK=Y
        	I_GIS=Y
        	;;
        --postgres)
        	I_PG=Y
        	;;
        ---nominatim)
        	I_NOM=Y
        	;;
        --website)
        	I_NOM=Y
        	I_SITE=Y
        	;;
        --import-nominatim)
        	I_PG=Y
        	I_NOM=Y
        	I_SITE=Y
        	;;
        --mapnik)
        	I_MAPNIK=Y
        	;;
        --import-gis)
        	I_PG=Y
        	I_MAPNIK=Y
        	I_GIS=Y
        	;;
        esac
done

if [[ "$TERM" != "screen" ]]; then
	echo "Commands must be run in a screen session. Exiting..."
	exit 2
fi

if [ "${I_PG}" == "Y" ] ; then
	echo "** Postgresql"
	init_pg
fi
if [ "${I_NOM}" == "Y" ] ; then
	echo "** Nominatim"
	init_nom
fi
if [ "${I_SITE}" == "Y" ] ; then
	echo "** Website"
	init_pg
fi
if [ "${I_OSM}" == "Y" ] ; then
	echo "** Import OSM"
	import_osm
fi
if [ "${I_MAPNIK}" == "Y" ] ; then
	echo "** Mapnik"
	setup_mapnik
fi
if [ "${I_GIS}" == "Y" ] ; then
	echo "** GIS"
	setup_mapnik
fi
