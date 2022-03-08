ORACLE_VERSION=${1:-19.14}
ORACLE_EDITION=${2:-EE}
TAG=${2:-7-slim}
SOURCE=${3:-oraclelinux}

. ./functions.sh

getEdition() {
  case $ORACLE_EDITION in
       EE)    ORACLE_EDITION_ARG="EE" ;;
       XE)    ORACLE_EDITION_ARG="XE"
              INSTALL_RESPONSE_ARG="oracle-${ORACLE_VERSION}-${ORACLE_EDITION}.conf"
              ORACLE_BASE_CONFIG_ARG="###"
              ORACLE_BASE_CONFIG_ENV="###"
              ORACLE_BASE_CONFIG_LABEL="###"
              ORACLE_BASE_HOME_ARG="###"
              ORACLE_BASE_HOME_ENV="###"
              ORACLE_BASE_HOME_LABEL="###"
              ORACLE_READ_ONLY_HOME_ARG="###"
              ORACLE_ROH_ENV="###"
                case $ORACLE_VERSION in
                     11.2.0.2) ORACLE_HOME_ARG="11.2.0/xe"
                               ;;
                     18.4)     MIN_SPACE_GB_ARG=13
                               ORACLE_HOME_ARG="18c/dbhomeXE"
                               ORACLE_PDB_ARG="ARG ORACLE_PDB=XEPDB"
                               ORACLE_RPM_ARG="ARG ORACLE_RPM=\"https://download.oracle.com/otn-pub/otn_software/db-express/oracle-database-xe-18c-1.0-1.x86_64.rpm\""
                               ;;
                     *)        error "Selected version ($ORACLE_VERSION) is not available for Express Edition"
                               ;;
                esac
              ;;
       SE*)   ORACLE_EDITION_ARG="SE" ;;
       *)     error "Invalid edition name ($ORACLE_EDITION) provided" ;;
  esac
}

getVersion() {
  # Set defaults
  DOCKER_RUN_LABEL="-e PDB_COUNT=<PDB COUNT> -e ORACLE_PDB=<PDB PREFIX> "
  INSTALL_RESPONSE_ARG="$ORACLE_VERSION"
  MIN_SPACE_GB_ARG=12
  ORACLE_SID_ARG="ORCLCDB"
  ORACLE_HOME_ARG="${ORACLE_VERSION}/dbhome_1"
  ORACLE_BASE_CONFIG_ARG="ARG ORACLE_BASE_CONFIG=\$ORACLE_BASE/dbs"
  ORACLE_BASE_CONFIG_ENV="ORACLE_BASE_CONFIG=\$ORACLE_BASE_CONFIG \\\\"
  ORACLE_BASE_CONFIG_LABEL="LABEL volume.oraclebaseconfig=\"\$ORACLE_BASE_CONFIG\""
  ORACLE_BASE_HOME_ARG="ARG ORACLE_BASE_HOME=\$ORACLE_BASE/homes"
  ORACLE_BASE_HOME_ENV="ORACLE_BASE_HOME=\$ORACLE_BASE_HOME \\\\"
  ORACLE_BASE_HOME_LABEL="LABEL volume.oraclebasehome=\"\$ORACLE_BASE_HOME\""
  ORACLE_PDB_ARG="ARG ORACLE_PDB="
  ORACLE_PDB_ENV="ORACLE_PDB=\$ORACLE_PDB \\\\"
  ORACLE_PDB_LABEL="LABEL database.default.pdb=\"\$ORACLE_PDB\""
  ORACLE_READ_ONLY_HOME_ARG="ARG ROOH="
  ORACLE_ROH_ENV="ROOH=\$ROOH \\\\"
  ORACLE_RPM_ARG=""
  PDB_COUNT_ARG="ARG PDB_COUNT=1"
  PDB_COUNT_ENV="PDB_COUNT=\$PDB_COUNT \\\\"
  PDB_COUNT_LABEL="LABEL database.default.pdb_count=\"\$PDB_COUNT\""

    if [ "$ORACLE_VERSION" == "11.2.0.2" ] || [ "$ORACLE_VERSION" == "18.4" ]
  then ORACLE_EDITION="XE"
  fi

  case $ORACLE_VERSION in
       11*)   ORACLE_BASE_VERSION="$ORACLE_VERSION"
              DOCKER_RUN_LABEL=""
              ORACLE_BASE_CONFIG_ARG="###"
              ORACLE_BASE_CONFIG_ENV="###"
              ORACLE_BASE_CONFIG_LABEL="###"
              ORACLE_BASE_HOME_ARG="###"
              ORACLE_BASE_HOME_ENV="###"
              ORACLE_BASE_HOME_LABEL="###"
              ORACLE_PDB_ARG="###"
              ORACLE_PDB_ENV="###"
              ORACLE_PDB_LABEL="###"
              ORACLE_READ_ONLY_HOME_ARG="###"
              ORACLE_SID_ARG=ORCL
              PDB_COUNT_ARG="###"
              PDB_COUNT_ENV="###"
              PCB_COUNT_LABEL="###"
              PREINSTALL_TAG="11g"
              ;;
       12*)   ORACLE_BASE_VERSION="$ORACLE_VERSION"
              ORACLE_BASE_CONFIG_ARG="###"
              ORACLE_BASE_CONFIG_ENV="###"
              ORACLE_BASE_CONFIG_LABEL="###"
              ORACLE_BASE_HOME_ARG="###"
              ORACLE_BASE_HOME_ENV="###"
              ORACLE_BASE_HOME_LABEL="###"
              ORACLE_READ_ONLY_HOME_ARG="###"
              PREINSTALL_TAG="$ORACLE_VERSION"
              ;;
       18*)   ORACLE_BASE_VERSION="$ORACLE_VERSION"
              ORACLE_HOME_ARG="18c/dbhome_1"
              PREINSTALL_TAG="18c"
              ;;
       19*)   ORACLE_BASE_VERSION=19
              INSTALL_RESPONSE_ARG="$ORACLE_BASE_VERSION"
              ORACLE_HOME_ARG="19c/dbhome_1"
              PREINSTALL_TAG="19c"
              ;;
       21*)   ORACLE_BASE_VERSION=21
              INSTALL_RESPONSE_ARG="$ORACLE_BASE_VERSION"
              ORACLE_HOME_ARG="21c/dbhome_1"
              PREINSTALL_TAG="21c"
              ;;
       *)     error "Invalid version ($ORACLE_VERSION) provided" ;;
  esac
}

getImage() {
  docker images --filter=reference="${SOURCE}:${TAG}-${PREINSTALL_TAG}" --format "{{.Repository}}:{{.Tag}}"
}

setBuildKit() {
  # Check whether Docker Build Kit is available; version must be 18.09 or greater.
  version=$(docker --version | awk '{print $3}')
  major_version=$((10#$(echo $version | cut -d. -f1)))
  minor_version=$((10#$(echo $version | cut -d. -f2)))

    if [ "$major_version" -gt 18 ] || [ "$major_version" -eq 18 -a "$minor_version" -gt 9 ]
  then BUILDKIT=1
  else BUILDKIT=0
  fi
}

createDockerfiles() {
  dockerfile=$(mktemp ./Dockerfile.$1.$(date '+%Y%m%d%H%M'))
  dockerignore=${dockerfile}.dockerignore

  chmod 664 $dockerfile
  # If FROM_BASE is set it means there was no existing oraclelinux image tagged
  # with the DB version. Create a full Dockerfile to build the OS, otherwise use
  # the existing image to save time.
  cat ./templates/$1.dockerfile > $dockerfile
  cat ./templates/$1.dockerignore > $dockerignore
}

processDockerfile() {
   for var in DOCKER_RUN_LABEL \
              FROM_BASE \
              FROM_OEL_BASE \
              INSTALL_RESPONSE_ARG \
              MIN_SPACE_GB_ARG \
              ORACLE_BASE_CONFIG_ARG \
              ORACLE_BASE_CONFIG_ENV \
              ORACLE_BASE_CONFIG_LABEL \
              ORACLE_BASE_HOME_ARG \
              ORACLE_BASE_HOME_ENV \
              ORACLE_BASE_HOME_LABEL \
              ORACLE_EDITION_ARG \
              ORACLE_HOME_ARG \
              ORACLE_PDB_ARG \
              ORACLE_PDB_ENV \
              ORACLE_PDB_LABEL \
              ORACLE_READ_ONLY_HOME_ARG \
              ORACLE_ROH_ENV \
              ORACLE_RPM_ARG \
              ORACLE_SID_ARG \
              ORACLE_VERSION \
              PDB_COUNT_ARG \
              PDB_COUNT_ENV \
              PDB_COUNT_LABEL
           do REPIFS=$IFS
              IFS=
              replaceVars "$1" "$var"
              IFS=$REPIFS
         done

  # Remove unset lines
  sed -i -e '/###$/d' $1
}

addException() {
  case $2 in
       database) local __path="database" ;;
       patch)    local __path="database/patches" ;;
       asset)    local __path="config" ;;
  esac
       printf '!/%s/%s\n' $__path $1 >> $dockerignore
}

createIgnorefile() {
    if [ -f ./config/manifest."$1" ]
  then 
       grep -ve "^#" ./config/manifest."$1" | awk '{print $2,$3,$4,$5}' | while IFS=" " read -r filename filetype version edition oel
          do
               if [ "$filetype" == "database" ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/"$filename" ] && [ -z "$edition" ]
             then addException $filename database
             elif [ "$filetype" == "database" ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/"$filename" ] && [[ $edition =~ $ORACLE_EDITION ]]
             then addException $filename database
#             elif [ "$filetype" == "database" ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/"$filename" ] && [[ $oel =~ ^$TAG.* ]]
#             then addException $filename database
             elif [ "$filetype" == "opatch"   ] && [ "$version" == "$ORACLE_BASE_VERSION" ] && [ -f ./database/patches/"$filename" ]
             then addException $filename patch
             elif [ "$filetype" == "patch" ]    && [ "$version" == "$ORACLE_VERSION" ]      && [ -f ./database/patches/"$filename" ]
             then addException $filename patch
             fi
        done
  fi
}

getVersion
getEdition
setBuildKit

# Set build options
options="--force-rm=true --no-cache=true"

# Set build arguments
arguments=""
  if [ -n "$RPM_LIST" ]
then rpm_list="--build-arg RPM_LIST=$RPM_LIST"
fi

  if [ -z "$(getImage)" ]
then # There is no base image
     # Create a base image:
     FROM_BASE="FROM oraclelinux:7-slim as base"
     FROM_OEL_BASE="base"
     createDockerfiles oraclelinux || error "There was a problem creating the Dockerfiles"
     processDockerfile $dockerfile

     # Run the build
     DOCKER_BUILDKIT=$BUILDKIT docker build --progress=plain $options $arguments $rpm_list \
                              --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                              -t ${SOURCE}:${TAG}-${PREINSTALL_TAG} \
                              -f $dockerfile . && rm $dockerfile $dockerignore
fi

FROM_OEL_BASE="$(getImage)"
echo $FROM_OEL_BASE
createDockerfiles db || error "There was a problem creating the Dockerfiles"
processDockerfile $dockerfile

# Add exceptions to the ignore file
  if [ "$ORACLE_BASE_VERSION" != "$ORACLE_VERSION" ]
then addException "*.$(echo $ORACLE_VERSION | cut -d. -f1).rsp" asset
     addException "*.$(echo $ORACLE_VERSION | cut -d. -f1)" asset
     addException "*.$ORACLE_VERSION" asset
else addException "*.${ORACLE_VERSION}.rsp" asset
     addException "*.${ORACLE_VERSION}" asset
fi
createIgnorefile $ORACLE_BASE_VERSION

DOCKER_BUILDKIT=$BUILDKIT docker build --progress=plain $options $arguments \
                         --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                         -t oraclesean/db:${ORACLE_VERSION}-${ORACLE_EDITION} \
                         -f $dockerfile . && rm $dockerfile $dockerignore
