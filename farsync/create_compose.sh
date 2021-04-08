# Set variables for environment
export BUILD_DIR=$PWD
export PORT_PREFIX=1000
export YAML_FILE=test.yml
export CONFIG_FILE=config-dataguard.lst

# Set variables used by Docker, Compose:
export COMPOSE_YAML=${BUILD_DIR}/${YAML_FILE}
export COMPOSE_CONFIG=${BUILD_DIR}/${CONFIG_FILE}
export TNS_FILE=${BUILD_DIR}/tnsnames.ora

# Create a docker-compose file and dynamically build the tnsnames.ora file
# Initialize the docker-compose file:
cat << EOF > $COMPOSE_YAML
version: '3'
services:
EOF

# Initialize the TNS file:
cat << EOF > $TNS_FILE
# tnsnames.ora file for Data Guard
EOF

# Populate the docker-compose.yml file:
egrep -v "^$|^#" $COMPOSE_CONFIG | sed -e 's/[[:space:]]//g' | while IFS='|' read CONTAINER_NAME CONTAINER_ID IMAGE_NAME ORACLE_SID DB_UNQNAME ORACLE_PWD PDB_COUNT PDB_NAME ROLE ROUTE_PRIORITY
do

# Write the Docker compose file entry:
cat << EOF >> $COMPOSE_YAML
  $CONTAINER_NAME:
    image: $IMAGE_NAME
    container_name: $CONTAINER_NAME
    volumes:
      - "FS_${CONTAINER_NAME}:/u01/app/oracle/oradata"
      - "FS_SHARE:/share"
    environment:
      CONTAINER_NAME: $CONTAINER_NAME
      ORACLE_SID: ${ORACLE_SID}
      DB_UNQNAME: ${DB_UNQNAME}
      ORACLE_PWD: ${ORACLE_PWD}
      PDB_COUNT: ${PDB_COUNT}
      PDB_NAME: ${PDB_NAME}
      ROLE: $ROLE
      ROUTE_PRIORITY: ${ROUTE_PRIORITY}
    ports:
      - "${PORT_PREFIX}${CONTAINER_ID}:1521"

EOF

# Write a tnsnames.ora entry for each instance in the configuration file:
cat << EOF >> $TNS_FILE
$CONTAINER_NAME =
(DESCRIPTION =
  (ADDRESS = (PROTOCOL = TCP)(HOST = $CONTAINER_NAME)(PORT = 1521))
  (CONNECT_DATA =
    (SERVER = DEDICATED)
    (UR = A)
    (SERVICE_NAME = $ORACLE_SID)
  )
)

EOF

  if [ "$(expr $PDB_COUNT + 0)" -gt 0 ]
then cat << EOF >> $TNS_FILE
${CONTAINER_NAME}PDB1=
(DESCRIPTION =
  (ADDRESS = (PROTOCOL = TCP)(HOST = $CONTAINER_NAME)(PORT = 1521))
  (CONNECT_DATA =
    (SERVER = DEDICATED)
    (SERVICE_NAME = ${ORACLE_PDB}
  )
)

EOF
fi

done

cat << EOF >> $COMPOSE_YAML

volumes:
  FS_SHARE:
EOF

egrep -v "^$|^#" $COMPOSE_CONFIG | sed -e 's/[[:space:]]//g' | sort | while IFS='|' read CONTAINER_NAME CONTAINER_ID IMAGE_NAME ORACLE_SID DB_UNQNAME ORACLE_PWD PDB_COUNT PDB_NAME ROLE ROUTE_PRIORITY
do
cat << EOF >> $COMPOSE_YAML
  FS_${CONTAINER_NAME}:
EOF
done
