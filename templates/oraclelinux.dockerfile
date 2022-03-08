###FROM_BASE###

# Directory defaults
ARG SCRIPTS_DIR=/opt/scripts
ARG ORACLE_PATH=/home/oracle

# Database defaults
ARG ORACLE_VERSION=###ORACLE_VERSION###
ARG ORACLE_BASE=/u01/app/oracle
ARG ORACLE_HOME=$ORACLE_BASE/product/###ORACLE_HOME_ARG###
###ORACLE_BASE_HOME_ARG###
###ORACLE_BASE_CONFIG_ARG###
ARG ORACLE_INV=/u01/app/oraInventory
ARG ORADATA=/opt/oracle/oradata
ARG ORACLE_EDITION=###ORACLE_EDITION_ARG###
ARG ORACLE_SID=###ORACLE_SID_ARG###
###ORACLE_PDB_ARG###
###PDB_COUNT_ARG###
###ORACLE_READ_ONLY_HOME_ARG###

# Build defaults
ARG RPM_LIST="oracle-epel-release-el7 file-5.11 git less strace sudo tree vi which bash-completion"
ARG RPM_SUPPLEMENT="rlwrap"
ARG MIN_SPACE_GB=###MIN_SPACE_GB_ARG###
ARG BUILD_DATE=
ARG BUILD_VERSION=1.0
# Pass --build-arg DEBUG="bash -x" to run scripts in debug mode.
ARG DEBUG=

# DB configuration defaults
ARG MANAGE_ORACLE=manageOracle.sh

# Labels
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.url="http://oraclesean.com"
LABEL org.label-schema.version="$BUILD_VERSION"
LABEL org.label-schema.build-date="$BUILD_DATE"
LABEL org.label-schema.vcs-url="https://github.com/oraclesean"
LABEL org.label-schema.name="oraclesean/oracledb-$ORACLE_VERSION-$ORACLE_EDITION"
LABEL org.label-schema.description="Extensible Oracle $ORACLE_VERSION database"
LABEL org.label-schema.docker.cmd="docker run -d --name <CONTAINER_NAME> -e ORACLE_SID=<ORACLE SID> ###DOCKER_RUN_LABEL###<IMAGE NAME>"
LABEL maintainer="Sean Scott <sean.scott@viscosityna.com>"
LABEL database.version="$ORACLE_VERSION"
LABEL database.edition="$ORACLE_EDITION"
LABEL volume.data="$ORADATA"
LABEL port.listener.listener1="1521"
LABEL port.oemexpress="5500"
LABEL port.http="8080"
LABEL database.default.sid="$ORACLE_SID"
###ORACLE_PDB_LABEL###
###PDB_COUNT_LABEL###

# Environment settings
ENV ORACLE_BASE=$ORACLE_BASE \
    ORACLE_HOME=$ORACLE_HOME \
    ORACLE_INV=$ORACLE_INV \
    ###ORACLE_BASE_HOME_ENV###
    ###ORACLE_BASE_CONFIG_ENV###
    ORADATA=$ORADATA \
    ORACLE_VERSION=$ORACLE_VERSION \
    ORACLE_EDITION=$ORACLE_EDITION \
    ORACLE_SID=$ORACLE_SID \
    ###ORACLE_PDB_ENV###
    ###PDB_COUNT_ENV###
    ###ORACLE_ROH_ENV###
    ORACLE_PATH=$ORACLE_PATH \
    SCRIPTS_DIR=$SCRIPTS_DIR \
    MANAGE_ORACLE=$MANAGE_ORACLE \
    ATTACH_HOME=$ATTACH_HOME \
    DEBUG=$DEBUG

ENV PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch/:/usr/sbin:$PATH \
    CLASSPATH=$ORACLE_HOME/jlib:$ORACLE_HOME/rdbms/jlib \
    LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib \
    TNS_ADMIN=$ORACLE_HOME/network/admin

COPY $MANAGE_ORACLE $SCRIPTS_DIR/

# Build base image:
RUN chmod ug+x $SCRIPTS_DIR/$MANAGE_ORACLE && \
    $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE -e && \
    rm -fr /tmp/* /var/cache/yum
