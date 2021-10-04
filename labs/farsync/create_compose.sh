#!/bin/bash
# Set variables for environment
export BUILD_DIR="$PWD"
export PORT_PREFIX=1000
export YAML_FILE=docker-compose.yml
export CONFIG_FILE=config-dataguard.lst

# Set variables used by Docker, Compose:
export COMPOSE_YAML="$BUILD_DIR"/"$YAML_FILE"
export COMPOSE_CONFIG="$BUILD_DIR"/"$CONFIG_FILE"
export TNS_FILE="$BUILD_DIR"/tnsnames.ora
export SETUP_PRIMARY=dg_setup_primary
export BROKER_SCRIPT=dg_broker.dgs
export BROKER_CHECKS=dg_check.dgs
export RMAN_DUPLICATE=rman_duplicate
export SETUP_DIR=/docker
export ORADATA=/u01/app/oracle/oradata
export TNS_PORT=1521

# Create a docker-compose file and dynamically build the tnsnames.ora file
# Initialize the docker-compose file:
printf "version: '3'\nservices:\n" > "$COMPOSE_YAML"

# Initialize the TNS file:
printf "# tnsnames.ora file for Data Guard\n" > "$TNS_FILE"

# Initialize the Broker file:
cat /dev/null > "$BUILD_DIR"/"$BROKER_SCRIPT"

# Populate the docker-compose.yml file:
egrep -v "^$|^#" "$COMPOSE_CONFIG" | sed -e 's/[[:space:]]//g' | while IFS='|' read CONTAINER_NAME CONTAINER_ID IMAGE_NAME ORACLE_SID DB_UNQNAME ORACLE_PWD PDB_COUNT PDB_NAME ROLE ROUTE_PRIORITY DG_TARGET SYNC_MODE MAXFAIL OPEN_MODE
   do
	# Write the Docker compose file entry:
	cat <<- EOF >> "$COMPOSE_YAML"
	  ${CONTAINER_NAME}:
	    image: ${IMAGE_NAME}
	    container_name: ${CONTAINER_NAME}
	    volumes:
	      - FS_${CONTAINER_NAME}:${ORADATA}
	      - ${BUILD_DIR}:${SETUP_DIR}
	    environment:
	      CONTAINER_NAME: ${CONTAINER_NAME}
	      ORACLE_SID: ${ORACLE_SID}
	      DB_UNQNAME: ${DB_UNQNAME}
	      ORACLE_PWD: ${ORACLE_PWD}
	      PDB_COUNT: ${PDB_COUNT}
	      PDB_NAME: ${PDB_NAME}
	      ROLE: ${ROLE}
	      DG_TARGET: ${DG_TARGET}
	      SETUP_DIR: ${SETUP_DIR}
	      BROKER_SCRIPT: ${BROKER_SCRIPT}
	      BROKER_CHECKS: ${BROKER_CHECKS}
	      SETUP_PRIMARY: ${SETUP_PRIMARY}
	      RMAN_DUPLICATE: ${RMAN_DUPLICATE}
	      OPEN_MODE: ${OPEN_MODE}

	    ports:
	      - ${PORT_PREFIX}${CONTAINER_ID}:${TNS_PORT}

EOF

	# Write a tnsnames.ora entry for each instance in the configuration file:
	cat <<- EOF >> "$TNS_FILE"
	${DB_UNQNAME} =
	  (DESCRIPTION =
	    (ADDRESS = (PROTOCOL = TCP)(HOST = ${CONTAINER_NAME})(PORT = ${TNS_PORT}))
	    (CONNECT_DATA =
	      (SERVER = DEDICATED)
	      (UR = A)
	      (SERVICE_NAME = ${ORACLE_SID})
	    )
	  )

EOF

	member_type="database"
	redo_route="$DB_UNQNAME $SYNC_MODE"
	long_route="$redo_route PRIORITY=${ROUTE_PRIORITY}"
	connect_id="'${CONTAINER_NAME}:${TNS_PORT}/${DB_UNQNAME}'"

	  if [ "$ROLE" = "PRIMARY" ]
	then printf "create configuration %s as primary database is %s connect identifier is %s;\n" "$ORACLE_SID" "$DB_UNQNAME" "$connect_id" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	     printf "edit database %s set property RedoRoutes = '(local:(###PRIMARY_REDO###))';\n" "$DB_UNQNAME" >> "$BUILD_DIR"/"$BROKER_SCRIPT".end
	     printf "sql \"alter system set log_archive_config='DG_CONFIG=(###DG_CONFIG###)' comment='For Far Sync' scope=both\";\n" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	     unset redo_route
	     unset long_route
	     # Initialize the Data Guard setup script
	     cat <<- EOF > "$BUILD_DIR"/"$SETUP_PRIMARY".sql
		spool /tmp/${SETUP_PRIMARY}.out
		alter system set adg_redirect_dml=TRUE comment='For Data Guard' scope=both;
		alter system set adg_account_info_tracking='GLOBAL' comment='For Data Guard' scope=spfile;
		alter system set db_create_file_dest='${ORADATA}' comment='For Data Guard' scope=both;
		alter system set db_create_online_log_dest_1='${ORADATA}' comment='For Data Guard' scope=both;
		alter system set db_recovery_file_dest_size=50g comment='For Data Guard' scope=both;
		alter system set db_recovery_file_dest='${ORADATA}' comment='For Data Guard' scope=both;
		alter system set dg_broker_config_file1='${ORADATA}/${DB_UNQNAME}/dr1${DB_UNQNAME}.dat' comment='For Data Guard' scope=both;
		alter system set dg_broker_config_file2='${ORADATA}/${DB_UNQNAME}/dr2${DB_UNQNAME}.dat' comment='For Data Guard' scope=both;
		alter system set dg_broker_start=true comment='For Data Guard' scope=both;
                alter system set fal_client='${ORACLE_SID}' comment='For Data Guard' scope=both;
		alter system set log_archive_format='%t_%s_%r.arc' comment='For Data Guard' scope=spfile;
		alter system set log_archive_max_processes=8 comment='For Data Guard' scope=both;
		alter system set remote_login_passwordfile='EXCLUSIVE' comment='For Data Guard' scope=spfile;
		alter system set standby_file_management='AUTO' comment='For Data Guard' scope=both;
		  declare
		          v_group v\$log.group#%TYPE;
		    begin
		      for l in (
		            select thread#, bytes, count(group#) groups
		              from v\$log
		          group by thread#, bytes
		          order by thread#, bytes)
		     loop
		            select max(group#) + 1
		              into v_group
		              from v\$logfile;
		                for s in 0..l.groups
		               loop execute immediate('alter database add standby logfile thread ' || to_char(l.thread#) || ' group ' || to_char(v_group + s) || ' size ' || to_char(l.bytes));
		           end loop;
		 end loop;
		      end;
		/
		shutdown immediate
		startup mount;
		alter database archivelog;
		alter database open;
		alter database force logging;
		alter system switch logfile;
		alter database flashback on;
EOF

	elif [ "$ROLE" = "STANDBY" ]
	then printf " add database %s as connect identifier is %s maintained as physical;\n" "$DB_UNQNAME" "$connect_id" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
             printf "edit database %s set property StaticConnectIdentifier = %s;\n" "$DB_UNQNAME" "$connect_id" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	     # Create a standby RMAN duplicate script
		cat <<- EOF > "$RMAN_DUPLICATE"."$DB_UNQNAME".rman
		connect auxiliary sys/${ORACLE_PWD}@${CONTAINER_NAME}:${TNS_PORT}/${DB_UNQNAME}
		duplicate target database
		      for standby
		     from active database
		          dorecover
		          spfile
		      set db_file_name_convert='${ORACLE_SID}','${DB_UNQNAME}' comment 'For Data Guard'
		      set db_unique_name='${DB_UNQNAME}' comment 'For Data Guard'
		      set dg_broker_config_file1='${ORADATA}/${DB_UNQNAME}/dr1${DB_UNQNAME}.dat' comment 'For Data Guard'
		      set dg_broker_config_file2='${ORADATA}/${DB_UNQNAME}/dr2${DB_UNQNAME}.dat' comment 'For Data Guard'
		      set fal_client='${DB_UNQNAME}' comment 'For Data Guard'
		      set fal_server='${ORACLE_SID}' comment 'For Data Guard'
		      set log_file_name_convert='${ORACLE_SID}','${DB_UNQNAME}' comment 'For Data Guard'
		          nofilenamecheck;
EOF

	elif [ "$ROLE" = "FARSYNC" ]
	then printf " add far_sync %s as connect identifier is %s;\n" "$DB_UNQNAME" "$connect_id" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	     member_type="far_sync"
	     # Create a Far Sync RMAN duplicate script
		cat <<- EOF > "$RMAN_DUPLICATE"."$DB_UNQNAME".rman
		connect auxiliary sys/${ORACLE_PWD}@${CONTAINER_NAME}:${TNS_PORT}/${DB_UNQNAME}
		duplicate target database
		      for farsync
		     from active database
		          spfile
		    reset control_files
		      set db_file_name_convert='${ORACLE_SID}','${DB_UNQNAME}' comment 'For Far Sync'
		      set db_unique_name='${DB_UNQNAME}' comment 'For Far Sync'
		      set dg_broker_config_file1='${ORADATA}/${DB_UNQNAME}/dr1${DB_UNQNAME}.dat' comment 'For Far Sync'
		      set dg_broker_config_file2='${ORADATA}/${DB_UNQNAME}/dr2${DB_UNQNAME}.dat' comment 'For Far Sync'
		      set dg_broker_start='TRUE' comment 'For Far Sync'
		      set fal_client='${DB_UNQNAME}' comment 'For Far Sync'
		      set fal_server='${ORACLE_SID}' comment 'For Far Sync'
		    reset log_archive_dest_2
		    reset log_archive_dest_3
		    reset log_archive_dest_4
		    reset log_archive_dest_5
		    reset log_archive_dest_6
		    reset log_archive_dest_7
		    reset log_archive_dest_8
		    reset log_archive_dest_9
		    reset log_archive_dest_10
		      set log_file_name_convert='${ORACLE_SID}','${DB_UNQNAME}' comment 'For Far Sync'
		      set sga_target='600M' comment 'For Far Sync';
EOF

	fi

	printf "edit $member_type %s set property HostName = '%s';\n" "$DB_UNQNAME" "$CONTAINER_NAME" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	printf "edit $member_type %s set property LogXptMode = '%s';\n" "$DB_UNQNAME" "$SYNC_MODE" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	printf "edit $member_type %s set property MaxFailure = %s;\n" "$DB_UNQNAME" "$MAXFAIL" >> "$BUILD_DIR"/"$BROKER_SCRIPT"

	  if [ -z "$dg_config" ]
	then export dg_config="$DB_UNQNAME"
	else export dg_config="$dg_config","$DB_UNQNAME"
	fi

	  if [ -z "$redo_routes" ]
	then export redo_routes="$redo_route"
	     export long_routes="$long_route"
	else
	       if [ "$ROLE" != "FARSYNC" ]
	     then export redo_routes="$redo_routes, $redo_route"
	          export long_routes="$long_routes, $long_route"
	     else export redo_routes="$redo_routes"
	          export long_routes="$long_route, $long_routes"
                  cat "$BUILD_DIR"/"$BROKER_SCRIPT".end >> "$BUILD_DIR"/"$BROKER_SCRIPT"
                  rm "$BUILD_DIR"/"$BROKER_SCRIPT".end
	          printf "edit far_sync %s set property RedoRoutes = '(%s: %s)';\n" "$DB_UNQNAME" "$ORACLE_SID" "$redo_routes" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	          printf "enable far_sync %s;\n" "$DB_UNQNAME" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
	          sed -i -e "s/###PRIMARY_REDO###/${long_routes}/" -e "s/###DG_CONFIG###/${dg_config}/" "$BUILD_DIR"/"$BROKER_SCRIPT"
	     fi
	fi

	  if [ "$(expr "$PDB_COUNT" + 0)" -gt 0 ]
	then cat <<- EOF >> "$TNS_FILE"
		${CONTAINER_NAME}${PDB_NAME} =
		(DESCRIPTION =
		  (ADDRESS = (PROTOCOL = TCP)(HOST = ${CONTAINER_NAME})(PORT = ${TNS_PORT}))
		  (CONNECT_DATA =
		    (SERVER = DEDICATED)
		    (SERVICE_NAME = ${PDB_NAME})
		  )
		)

EOF
	fi

 done

printf "volumes:\n" >> "$COMPOSE_YAML"
printf "enable configuration;\n" >> "$BUILD_DIR"/"$BROKER_SCRIPT"
printf "show configuration verbose;\n" > "$BUILD_DIR"/"$BROKER_CHECKS"

egrep -v "^$|^#" "$COMPOSE_CONFIG" | sed -e 's/[[:space:]]//g' | while IFS='|' read CONTAINER_NAME CONTAINER_ID IMAGE_NAME ORACLE_SID DB_UNQNAME ORACLE_PWD PDB_COUNT PDB_NAME ROLE ROUTE_PRIORITY DG_TARGET SYNC_MODE MAXFAIL
   do printf "  FS_%s:\n" "$CONTAINER_NAME" >> "$COMPOSE_YAML"
	      member_type="database"
	        if [ "$ROLE" = "FARSYNC" ]; then member_type="far_sync"; fi
	      printf "show %s verbose %s;\n" "$member_type" "$DB_UNQNAME" >> "$BUILD_DIR"/"$BROKER_CHECKS"
 done
