#!/bin/bash
#----------------------------------------------------------#
#                                                          #
#               Oracle Container Management                #
#                                                          #
# This script is used to perform all management functions  #
# for Oracle database containers. The default action is to #
# build a database by running DBCA. Other options include: #
#                                                          #
#    healthcheck: Perform the Docker health check          #
#                                                          #
#                                                          #
#                                                          #
#                                                          #
#                                                          #
#----------------------------------------------------------#

ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET:-AL32UTF8}
ORACLE_NLS_CHARACTERSET=${ORACLE_NLS_CHARACTERSET:-AL16UTF16}

logger() {
  printf "$@ \n"
}

warn() {
  printf "WARNING: $@\n"
}

error() {
  printf "ERROR: $@ \nExiting...\n"
  return 1
}

debug() {
  __s1=
  __s2=
    if [ "$debug" ]
  then __s1="DEBUG: $1"
       __s2="$(echo $2 | sed 's/\n//g')"
       printf "%-40s: %s\n" "$__s1" "$__s2" | tee -a $3
  fi
}

fixcase() {
  echo $1 | tr 'A-Z' 'a-z'
}

FIXCASE() {
  echo $1 | tr 'a-z' 'A-Z'
}

_sigint() {
  logger "\n${FUNCNAME[0]}: SIGINT recieved: stopping database"
  stopDB
}

_sigterm() {
  logger "\n${FUNCNAME[0]}: SIGTERM received: stopping database"
  stopDB
}

_sigkill() {
  logger "\n${FUNCNAME[0]}: SIGKILL received: Stopping database"
  stopDB
}

checkDirectory() {
    if [ ! -d "$1" ]
  then error "Directory $1 does not exist"
  elif [ ! -w "$1" ]
  then error "Directory $1 is not writable"
  fi
}

configENV() {
  set -e

  local __min_space_gb=${MIN_SPACE_GB:-12}
    if [ ! "$(df -PB 1G / | tail -n 1 | awk '{print $4}')" -ge "$__min_space_gb" ]
  then error "The build requires at least $__min_space_gb GB free space.\n"
  fi

    # Set the default RPM by version:
  case $ORACLE_VERSION in
       11.*)     local __rpm_list="oracle-database-preinstall-19c openssl" ;;
       12.1*)    local __rpm_list="oracle-rdbms-server-12cR1-preinstall openssl tar" ;;
       12.2*)    local __rpm_list="oracle-database-server-12cR2-preinstall openssl" ;;
       18.*)     local __rpm_list="oracle-database-preinstall-18c openssl" ;;
       19.*)     local __rpm_list="oracle-database-preinstall-19c openssl" ;;
  esac

    if [ ! -z "$RPM_LIST" ]
  then local __rpm_list="$__rpm_list $RPM_LIST"
  fi

  yum -y update
  yum -y install $__rpm_list
  sync

    if [ ! -z "$RPM_SUPPLEMENT" ]
  then yum -y install $RPM_SUPPLEMENT
  fi

  mkdir -p {$ORACLE_INV,$ORACLE_HOME,$ORADATA/dbconfig,$ORACLE_BASE/{admin,scripts/{setup,startup}}} || error "Failure creating directories.\n"
  chown -R oracle:oinstall $SCRIPTS_DIR $ORACLE_INV $ORACLE_BASE $ORADATA                            || error "Failure changing directory ownership."
  ln -s $ORACLE_BASE/scripts /docker-entrypoint-initdb.d                                             || error "Failure setting Docker entrypoint."
  echo oracle:oracle | chpasswd                                                                      || error "Failure setting the oracle user password."
  #    # Let oracle run rpm config:
  #    echo "oracle ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/oracle && \
  #    chmod 0440 /etc/sudoers.d/oracle && \
  yum clean all
}

checkSum() {
  # $1 is the file name containing the md5 hashes
  # $2 is the extension to check
  egrep "${2}$" $1 | while read checksum_value filename
    do
       # md5sum is present and values do not match
         if [ "$(type md5sum 2>/dev/null)" ] && [ !"$(md5sum $INSTALL_DIR/$filename | awk '{print $1}')" == "$checksum_value" ]
       then error "Checksum for $filename did not match"
       else unzip -q -d $INSTALL_DIR $INSTALL_DIR/$filename
       fi
  done
}

installOracle() {
  set -e

    if [ -z "$ORACLE_EDITION" ]
  then error "A database edition is required"
  elif [ "$ORACLE_EDITION" != "EE" -a "$ORACLE_EDITION" != "SE" -a "$ORACLE_EDITION" != "SE2" -a "$ORACLE_EDITION" != "XE" ]
  then error "Database edition must be one of EE, SE, SE2, or XE"
  elif [ "$ORACLE_VERSION" == "11.2.0.4" ] && [ "$ORACLE_EDITION" != "EE" -a "$ORACLE_EDITION" != "SE" ]
  then error "Database edition must be EE or SE for version 11.2.0.4"
  elif [ "$ORACLE_VERSION" == "11.2.0.2" ] && [ "$ORACLE_EDITION" != "XE" ]
  then error "Database edition must be XE for version 11.2.0.2"
  elif [ "$ORACLE_EDITION" == "SE" ]
  then error "Database edition SE is only available for version 11.2.0.4"
  fi

  checkDirectory $ORACLE_BASE
  checkDirectory $ORACLE_HOME

  sed -i -e "s|###ORACLE_EDITION###|$ORACLE_EDITION|g" \
         -e "s|###ORACLE_INV###|$ORACLE_INV|g" \
         -e "s|###ORACLE_BASE###|$ORACLE_BASE|g" \
         -e "s|###ORACLE_HOME###|$ORACLE_HOME|g" $INSTALL_DIR/$INSTALL_RESPONSE

  # Fix a problem that prevents root from su - oracle:
  sed -i -e "s|\(^session\s*include\s*system-auth\)|#\1|" /etc/pam.d/su

  # Install Oracle binaries
    if [ -f "$(find $INSTALL_DIR/ -iregex .*oracle.*\.rpm.*)" ] || [ ! -z "$ORACLE_RPM" ] || [ "${ORACLE_DOCKER_INSTALL^^}" ]
  then # Install Oracle from RPM
       # The ORACLE_DOCKER_INSTALL environment variable is required for RPM installation to succeed
       export ORACLE_DOCKER_INSTALL=true
         if [ -z "$ORACLE_RPM" ]
       then ORACLE_RPM=$(find $INSTALL_DIR/ -iregex .*oracle.*\.rpm.*)
              if [[ $ORACLE_RPM =~ .*\.zip$ ]]
            then unzip -q $ORACLE_RPM
                 ORACLE_RPM=${ORACLE_RPM%.zip}
            fi
       fi

       yum -y localinstall $ORACLE_RPM

       # If different directories are passed to the build, move the directories and recompile.
       export OLD_HOME=$(egrep "^export ORACLE_HOME" /etc/init.d/$INIT_FILE | cut -d= -f2 | tr -d '[:space:]')
       export OLD_BASE=$(echo $OLD_HOME | sed -e "s|/product.*$||g")
       export OLD_INV=$(egrep "^inventory_loc" $OLD_HOME/oraInst.loc | cut -d= -f2)
         if [[ ! $OLD_BASE -ef $ORACLE_BASE ]] || [[ ! $OLD_HOME -ef $ORACLE_HOME ]] || [[ ! $OLD_INV -ef $ORACLE_INV ]]
       then 
            # Directories cannot be changed in XE. It does not have the ability to relink.
              if [ "$ORACLE_EDITION" == "XE" ] # TODO: clone.pl is deprecated in 19c: -o "$(echo $ORACLE_VERSION | cut -c 1-2)" == "19"  ]
            then export ORACLE_HOME=$OLD_HOME
                 export ORACLE_BASE=$OLD_BASE
                 export ORACLE_INV=$OLD_INV
            fi
       
            # Move directories to new locations
              if [[ ! $OLD_HOME -ef $ORACLE_HOME ]]; then mv $OLD_HOME/* $ORACLE_HOME/ && rm -fr $OLD_BASE/product; fi
              if [[ ! $OLD_INV  -ef $ORACLE_INV ]];  then mv $OLD_INV/*  $ORACLE_INV/;  fi
              if [[ ! $OLD_BASE -ef $ORACLE_BASE ]]; then mv $OLD_BASE/* $ORACLE_BASE/; fi
            sed -i -e "s|^export ORACLE_HOME=.*$|export ORACLE_HOME=$ORACLE_HOME|g" \
                   -e "s|^export TEMPLATE_NAME=.*$|export TEMPLATE_NAME=$INSTALL_TEMPLATE|g" \
                   -e "s|^CONFIG_NAME=.*$|CONFIG_NAME=\"$INSTALL_RESPONSE\"|g" /etc/init.d/$INIT_FILE
            chown -R oracle:oinstall $ORACLE_HOME
            sed -i -e "s|^inventory_loc=.*$|inventory_loc=$ORACLE_INV|g" $ORACLE_HOME/oraInst.loc
            sudo su - oracle -c "$ORACLE_HOME/perl/bin/perl $ORACLE_HOME/clone/bin/clone.pl ORACLE_HOME=$ORACLE_HOME ORACLE_BASE=$ORACLE_BASE -defaultHomeName -invPtrLoc $ORACLE_HOME/oraInst.loc"
  	 fi
       chgrp oinstall /etc/init.d/$INIT_FILE
       chgrp oinstall /etc/sysconfig/oracle*
  else # Install Oracle from archive

       case $(ls $INSTALL_DIR/Checksum* 2>/dev/null | wc -l) in
         0) unzip -q -d $INSTALL_DIR $INSTALL_DIR/"*.zip";;
         1) checkSum $INSTALL_DIR/Checksum zip;;
         *) checkSum $INSTALL_DIR/Checksum.${ORACLE_EDITION} zip;;
       esac

       chown -R oracle:oinstall $INSTALL_DIR/*

       # Match the install command to the version
       case $ORACLE_VERSION in       
            18.*|19.*) sudo su - oracle -c "$ORACLE_HOME/runInstaller -silent -force -waitforcompletion -responsefile $INSTALL_DIR/$INSTALL_RESPONSE -ignorePrereqFailure" ;;
                    *) sudo su - oracle -c "$INSTALL_DIR/database/runInstaller -silent -force -waitforcompletion -responsefile $INSTALL_DIR/$INSTALL_RESPONSE -ignoresysprereqs -ignoreprereq" ;;
       esac

         if [ ! "$($ORACLE_HOME/perl/bin/perl -v)" ]
       then mv $ORACLE_HOME/perl $ORACLE_HOME/perl.old
            curl -o i$INSTALL_DIR/perl.tar.gz http://www.cpan.org/src/5.0/perl-5.14.1.tar.gz
            tar -xzf $INSTALL_DIR/perl.tar.gz
            cd $INSTALL_DIR/perl-*
            sudo su - oracle -c "./Configure -des -Dprefix=$ORACLE_HOME/perl -Doptimize=-O3 -Dusethreads -Duseithreads -Duserelocatableinc"
            sudo su - oracle -c "make clean"
            sudo su - oracle -c "make"
            sudo su - oracle -c "make install"

            # Copy old binaries into new Perl directory
            rm -fr $ORACLE_HOME/{lib,man}
            cp -r $ORACLE_HOME/perl.old/lib/            $ORACLE_HOME/perl/
            cp -r $ORACLE_HOME/perl.old/man/            $ORACLE_HOME/perl/
            cp    $ORACLE_HOME/perl.old/bin/dbilogstrip $ORACLE_HOME/perl/bin/
            cp    $ORACLE_HOME/perl.old/bin/dbiprof     $ORACLE_HOME/perl/bin/
            cp    $ORACLE_HOME/perl.old/bin/dbiproxy    $ORACLE_HOME/perl/bin/
            cp    $ORACLE_HOME/perl.old/bin/ora_explain $ORACLE_HOME/perl/bin/
            rm -fr $ORACLE_HOME/perl.old
            cd $ORACLE_HOME/lib
            ln -sf ../javavm/jdk/jdk7/lib/libjavavm12.a
            chown -R oracle:oinstall $ORACLE_HOME

            # Relink
            cd $ORACLE_HOME/bin
            sudo su - oracle -c "relink all"
              if [ "$?" -ne 0 ]
            then echo "Relink failed!"
                 cat "$ORACLE_HOME/install/relink.log"
                 exit 1
            fi
       fi

  fi

echo "Checking for patches"
ls -l $INSTALL_DIR

  # Check for OPatch
#         if [ -d "$INSTALL_DIR/OPatch" ]
#       then rm -fr $ORACLE_HOME/OPatch
    if [ "$(find $INSTALL_DIR -type f -name p6880880*.zip 2>/dev/null)" ]
  then sudo su - oracle -c "unzip -oq -d $ORACLE_HOME $INSTALL_DIR/p6880880*.zip"
#       sudo su - oracle -c "mv $INSTALL_DIR/OPatch $ORACLE_HOME/"
  fi

       # Check for patches
    if [ -d "$INSTALL_DIR/patches" ] 
  then
        for patchdir in $(ls -d $INSTALL_DIR/patches/*/ | egrep "[0-9]{3}/" | sed "s|/$||" | sort -n)
         do cd $patchdir
              if [ $(find . -type f -name *.zip) ]
            then unzip -q *.zip
                 chown -R oracle:oinstall .
                 cd */
                 # Get the apply command from the README
                 opatch_apply=$(egrep "opatch .apply" README.* | sort | head -1 | awk '{print $2}')
                 opatch_apply=${opatch_apply:-apply}
                 patchdir=$(pwd)
                 # Apply the patch
                 sudo su - oracle -c "$ORACLE_HOME/OPatch/opatch $opatch_apply -silent $patchdir"
                   if [ "$?" != "0" ]
                 then error "OPatch returned an error $rc"
                 fi
            fi
       done
  fi

  # Minimize the installation
    if [ ! -z "$REMOVE_COMPONENTS" ]
  then local __rc=${1^^}

       OLDIFS=$IFS
       IFS=,
        for rc in $__rc
         do
            case $rc in
                 APEX)  # APEX
                        rm -fr $ORACLE_HOME/apex 2>/dev/null ;;
                 DBMA)  # Database migration assistant
                        rm -fr $ORACLE_HOME/dmu 2>/dev/null ;;
                 DBUA)  # DBUA
                        rm -fr $ORACLE_HOME/assistants/dbua 2>/dev/null ;;
                 HELP)  # Help files
                        rm -fr $ORACLE_HOME/network/tools/help 2>/dev/null ;;
                 ORDS)  # ORDS
                        rm -fr $ORACLE_HOME/ords 2>/dev/null ;;
                 OUI)   # OUI inventory backups
                        rm -fr $ORACLE_HOME/inventory/backup/* 2>/dev/null ;;
                 PILOT) # Pilot workflow
                        rm -fr $ORACLE_HOME/install/pilot 2>/dev/null ;;
                 SQLD)  # SQL Developer
                        rm -fr $ORACLE_HOME/sqldeveloper 2>/dev/null ;;
                 SUP)   # Support tools
                        rm -fr $ORACLE_HOME/suptools 2>/dev/null ;;
                 TNS)   # TNS samples
                        rm -fr $ORACLE_HOME/network/admin/samples 2>/dev/null ;;
                 UCP)   # UCP
                        rm -fr $ORACLE_HOME/ucp 2>/dev/null ;;
                 ZIP)   # Installation files
                        rm -fr $ORACLE_HOME/lib/*.zip 2>/dev/null ;;
            esac
       done
       IFS=$OLDIFS
  fi

  # Revert /etc/pam.d/su:
  sed -i -e "s|^\(#\)\(session\s*include\s*system-auth\)|\2|" /etc/pam.d/su
}

runsql() {
  unset spool
    if [ ! -z "$2" ]
  then spool="spool $2 append"
  fi

  NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
  $ORACLE_HOME/bin/sqlplus -S / as sysdba <<EOF
set head off termout on verify off lines 300 pages 9999 trimspool on feed off serverout on
whenever sqlerror exit warning
$1
EOF

    if [ "$?" -ne 0 ]
  then error "${FUNCNAME[0]} failed calling SQL: $1"
       return 1
  fi
}

startDB() {
    if [ ! -z "$ORACLE_HOME" ] && [ ! -z "$ORACLE_SID" ]
  then $ORACLE_HOME/bin/lsnrctl start
       runsql "startup;"
  else error "${FUNCNAME[0]} failed to start the database: ORACLE_HOME and ORACLE_SID must be set."
       return 1
  fi
}

stopDB() {
  runsql "shutdown immediate;"
  $ORACLE_HOME/bin/lsnrctl stop
}

runDBCA() {
  local __version=$(echo $ORACLE_VERSION | cut -d. -f1)

  $ORACLE_HOME/bin/lsnrctl start
  unset __pdb_only

  logger "\n${FUNCNAME[0]}: Running DBCA for database $ORACLE_SID"

    if [ "$__version" != "11" ] && [ ! -z "$PDB_LIST" ]
  then OLDIFS=$IFS
       IFS=,
       PDB_NUM=1
       PDB_ADMIN=PDBADMIN
        for PDB_NAME in $PDB_LIST
         do
              if [ "$PDB_NUM" -eq 1 ]
            then # Create the database and the first PDB
                 logger "\n${FUNCNAME[0]}: Creating container database $ORACLE_SID and pluggable database $PDB_NAME \n"
                 cp $SCRIPTS_DIR/dbca.rsp $ORACLE_BASE/dbca.$ORACLE_SID.rsp
                 createDatabase $ORACLE_BASE/dbca.$ORACLE_SID.rsp TRUE 1 $PDB_NAME $PDB_ADMIN
                 PDBENV="export ORACLE_PDB=$PDB_NAME"
            else # Create additional PDB
                 logger "\n${FUNCNAME[0]}: Creating pluggable database $PDB_NAME \n"
                 createDatabase NONE TRUE 1 $PDB_NAME $PDB_ADMIN
            fi
            addTNSEntry $PDB_NAME
            PDB_NUM=$((PDB_NUM+1))
       done
       IFS=$OLDIFS
       alterPluggableDB
  elif [ "$__version" != "11" ] && [ "$PDB_COUNT" -gt 0 ]
  then PDB_ADMIN=PDBADMIN
       logger "\n${FUNCNAME[0]}: Creating container database $ORACLE_SID and $PDB_COUNT pluggable database(s) with name $ORACLE_PDB \n"
       cp $SCRIPTS_DIR/dbca.rsp $ORACLE_BASE/dbca.$ORACLE_SID.rsp
       createDatabase $ORACLE_BASE/dbca.$ORACLE_SID.rsp TRUE $PDB_COUNT $ORACLE_PDB $PDB_ADMIN
         if [ "$PDB_COUNT" -eq 1 ]
       then PDBENV="export ORACLE_PDB=$ORACLE_PDB"
            addTNSEntry $ORACLE_PDB
       else PDBENV="export ORACLE_PDB=${ORACLE_PDB}1"
             for ((PDB_NUM=1; PDB_NUM<=PDB_COUNT; PDB_NUM++))
              do addTNSEntry ${ORACLE_PDB}${PDB_NUM}
            done
       fi
       alterPluggableDB
  else logger "\n${FUNCNAME[0]}: Creating database $ORACLE_SID \n"
       cp $SCRIPTS_DIR/dbca.rsp $ORACLE_BASE/dbca.$ORACLE_SID.rsp
       createDatabase $ORACLE_BASE/dbca.$ORACLE_SID.rsp FALSE
       PDBENV="unset ORACLE_PDB"
  fi
  logger "\n${FUNCNAME[0]}: DBCA complete\n"
}

createDatabase() {
  local RESPONSEFILE=$1
  local CREATE_CONTAINER=${2:-TRUE}
  local PDBS=${3:-1}
  local PDB_NAME=${4:-ORCLPDB}
  local PDB_ADMIN=${5:-PDBADMIN}
  local dbcaLogDir=$ORACLE_BASE/cfgtoollogs/dbca

    if [ "$RESPONSEFILE" != "NONE" ]
  then
        for var in ORACLE_BASE \
                   ORACLE_SID \
                   ORACLE_PWD \
                   ORACLE_CHARACTERSET \
                   ORACLE_NLS_CHARACTERSET \
                   CREATE_CONTAINER \
                   PDBS \
                   PDB_NAME \
                   PDB_ADMIN
         do sed -i -e "s|###${var}###|$(eval echo \$$(echo $var))|g" $RESPONSEFILE
       done

       # If there is greater than 8 CPUs default back to dbca memory calculations
       # dbca will automatically pick 40% of available memory for Oracle DB
       # The minimum of 2G is for small environments to guarantee that Oracle has enough memory to function
       # However, bigger environment can and should use more of the available memory
       # This is due to Github Issue #307
         if [ "$(nproc)" -gt 8 ]
       then sed -i -e 's|TOTALMEMORY = "2048"||g' $RESPONSEFILE
       fi
       $ORACLE_HOME/bin/dbca -silent -createDatabase -responseFile $RESPONSEFILE || cat $dbcaLogDir/$ORACLE_SID/$ORACLE_SID.log || cat $dbcaLogDir/$ORACLE_SID.log || cat $dbcaLogDir/$ORACLE_SID/$PDB_NAME/$ORACLE_SID.log
  else $ORACLE_HOME/bin/dbca -silent -createPluggableDatabase -pdbName $PDB_NAME -sourceDB $ORACLE_SID -createAsClone true -createPDBFrom DEFAULT -pdbAdminUserName $PDB_ADMIN -pdbAdminPassword $ORACLE_PWD || cat $dbcaLogDir/$ORACLE_SID/$ORACLE_SID.log || cat $dbcaLogDir/$ORACLE_SID.log || cat $dbcaLogDir/$ORACLE_SID/$PDB_NAME/$ORACLE_SID.log
  fi

}

moveFiles() {
    if [ ! -d "$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID" ]
  then mkdir -p $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID
  fi

  local __dbconfig=$ORADATA/dbconfig/$ORACLE_SID

   for filename in $ORACLE_HOME/dbs/init$ORACLE_SID.ora \
                   $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora \
                   $ORACLE_HOME/dbs/orapw$ORACLE_SID \
                   $ORACLE_HOME/network/admin/listener.ora \
                   $ORACLE_HOME/network/admin/tnsnames.ora \
                   $ORACLE_HOME/network/admin/sqlnet.ora
    do
       file=$(basename $filename)
         if [ -f "$filename" ] && [ ! -f "$__dbconfig/$file" ]
       then mv $filename $__dbconfig/ 2>/dev/null
       fi
         if [ -f "$__dbconfig/$file" ] && [ ! -L "$filename" ]
       then ln -s $__dbconfig/$file $filename 2>/dev/null
       fi
  done

  cp /etc/oratab $__dbconfig/ 2>/dev/null

    if [ -f "$__dbconfig/oratab" ] && [ ! -f /etc/oratab ]
  then cp $__dbconfig/oratab /etc/oratab 2>/dev/null
  fi
}

addTNSEntry() {
  ALIAS=$1
  cat << EOF >> $ORACLE_HOME/network/admin/tnsnames.ora
$ALIAS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $ALIAS)
    )
  )
EOF
}

alterPluggableDB() {
  $ORACLE_HOME/bin/sqlplus -S / as sysdba << EOF
alter pluggable database all open;
alter pluggable database all save state;
EOF
}

HealthCheck() {
  local __open_mode="'READ WRITE'"
  local __tabname="v\$database"
  local __pdb_count=${PDB_COUNT:-0}

  source oraenv <<< $(egrep "\:${ORACLE_HOME}\:" /etc/oratab | cut -d: -f1 | head -1) 1>/dev/null
  rc="$?"

    if [ "$rc" -ne 0 ]
  then error "Failed to get the Oracle environment from oraenv"
       exit 1
  elif [ -z "$ORACLE_SID" ]
  then error "ORACLE_SID is not set"
       exit 1
  elif [ -z "$ORACLE_HOME" ]
  then error "ORACLE_HOME is not set"
       exit 1
  elif [ ! -f "$ORACLE_HOME/bin/sqlplus" ]
  then error "Cannot locate $ORACLE_HOME/bin/sqlplus"
       exit 1
  elif [ "$__pdb_count" -gt 0 -o ! -z "$PDB_LIST" ]
  then __tabname="v\$pdbs"
  fi

  health=$($ORACLE_HOME/bin/sqlplus -S / as sysdba << EOF
set head off pages 0 trimspool on feed off serverout on
whenever sqlerror exit warning
select count(*) from $__tabname where open_mode=$__open_mode;
EOF
)

    if [ "$?" -ne 0 ]
  then return 2
  elif [ "$health" -gt 0 ]
  then return 0
  else return 1
  fi
}

runUserScripts() {
  local SCRIPTS_ROOT="$1";

    if [ -z "$SCRIPTS_ROOT" ]
  then warn "No script path provided"
       exit 1
  elif [ -d "$SCRIPTS_ROOT" ] && [ -n "$(ls -A $SCRIPTS_ROOT)" ]
  then # Check that directory exists and it contains files
       logger "\n${FUNCNAME[0]}: Running user scripts\n"
        for f in $SCRIPTS_ROOT/*
         do
            case "$f" in
                 *.sh)     logger "\n${FUNCNAME[0]}: Script: $f \n"; . "$f" ;;
                 *.sql)    logger "\n${FUNCNAME[0]}: Script: $f \n"; echo "exit" | $ORACLE_HOME/bin/sqlplus -s "/ as sysdba" @"$f" ;;
                 *)        logger "\n${FUNCNAME[0]}: Ignored file $f \n" ;;
            esac
       done

       logger "\n${FUNCNAME[0]}: User scripts complete\n"
  fi
}

changePassword() {
  runsql "alter user sys identified by \"$1\";
          alter user system identified by \"$1\";"
# TODO: Loop through PDB
#  runsql "alter user pdbadmin identified by \"$1\";"
}

#----------------------------------------------------------#
#                           MAIN                           #
#----------------------------------------------------------#
ORACLE_CHARACTERSET=${ORACLE_CHARACTERSET:-AL32UTF8}
ORACLE_NLS_CHARACTERSET=${ORACLE_NLS_CHARACTERSET:-AL16UTF16}

# If a parameter is passed to the script, run the associated action.
while getopts ":ehOPR" opt; do
      case ${opt} in
           h) # Check health of the database
              HealthCheck
                if [ "$?" -eq 0 ]
              then exit 0
              else exit 1
              fi ;;
           e) # Configure environment
              configENV
              exit 0 ;;
           O) # Install Oracle
              installOracle
              exit 0 ;;
           P) # Change passwords
              # TODO: Get the password from the CLI
              changePassword
              exit 0 ;;
      esac
 done

# Start the database if no option is provided
trap _sigint SIGINT
trap _sigterm SIGTERM
trap _sigkill SIGKILL

# Check whether container has enough memory
# Github issue #219: Prevent integer overflow,
# only check if memory digits are less than 11 (single GB range and below)
__mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)

  if [ "$(echo $__mem | wc -c)" -lt 11 ] && [ "$__mem" -lt 2147483648 ]
then error "The database container requires at least 2GB of memory; only $__mem is available"
fi

  if [ "$(hostname | egrep -c "_")" -gt 0 ]
then error "The host name may not contain any '_'"
fi

# Validate SID, PDB names
__oracle_sid=${ORACLE_SID:-ORCLCDB}
__oracle_pdb=${ORACLE_PDB}
__pdb_count=${PDB_COUNT:-0}
__pdb_list=${PDB_LIST}

# Validate the SID:
  if [ "${#__oracle_sid}" -gt 12 ]
then error "The SID may not be longer than 12 characters"
elif [[ "$__oracle_sid" =~ [^a-zA-Z0-9] ]]
then error "The SID must be alphanumeric"
# Check PDB settings.
elif [ -z "$__oracle_pdb" ] && [ "$__pdb_count" -eq 0 ] && [ -z "$__pdb_list" ]
then # No PDB name + no PDB count + no PDB list = Not a container DB
     export ORACLE_SID=${__oracle_sid:-ORCL}
     unset ORACLE_PDB
     unset PDB_COUNT
     unset PDB_LIST
elif [ -z "$__oracle_pdb" ] && [ "$__pdb_count" -gt 0 ]
then # No PDB name but PDB count > 0
     export ORACLE_PDB=ORCLPDB
else export ORACLE_SID=$__oracle_sid
     export ORACLE_PDB=$__oracle_pdb
fi

#  # Make ORACLE_SID upper case
#  export ORACLE_SID=${ORACLE_SID^^}

## Make ORACLE_PDB upper case
#export ORACLE_PDB=${ORACLE_PDB^^}

# Check the audit path
  if [ ! -d $ORACLE_BASE/admin/$ORACLE_SID/adump ]
then mkdir -p $ORACLE_BASE/admin/$ORACLE_SID/adump
fi

# Check whether database already exists
  if [ "$(egrep -c "^$ORACLE_SID\:" /etc/oratab)" -eq 1 ] && [ -d "$ORACLE_BASE/oradata/$ORACLE_SID" ]
then moveFiles
     startDB 
else # Create the TNS configuration
     mkdir -p $ORACLE_HOME/network/admin 2>/dev/null
     echo "NAME.DIRECTORY_PATH=(TNSNAMES, EZCONNECT, HOSTNAME)" > $ORACLE_HOME/network/admin/sqlnet.ora

     cat << EOF > $ORACLE_HOME/network/admin/listener.ora
LISTENER = 
  (DESCRIPTION_LIST = 
    (DESCRIPTION = 
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1)) 
      (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521)) 
    ) 
  ) 

DEDICATED_THROUGH_BROKER_LISTENER=ON
DIAG_ADR_ENABLED = off
EOF

     echo "$ORACLE_SID=localhost:1521/$ORACLE_SID" > $ORACLE_HOME/network/admin/tnsnames.ora

     # Create a database password if none exists
       if [ -z "$ORACLE_PWD" ]
     then export ORACLE_PWD=$(openssl rand -base64 8)1
          logger "\n${FUNCNAME[0]}: ORACLE PASSWORD FOR SYS, SYSTEM AND PDBADMIN: $ORACLE_PWD"
     fi

     runDBCA

     # Run post-database creation alterations
     runsql "alter system set control_files='$ORADATA/$ORACLE_SID/control01.ctl' scope=spfile;"

     moveFiles

     # Create the user profile
    cat << EOF >> $HOME/.bashrc
export PS1="[\u - \\\${ORACLE_SID}] \w\n# "

export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$ORACLE_HOME
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch/:/usr/sbin:$PATH 
export CLASSPATH=$ORACLE_HOME/jlib:$ORACLE_HOME/rdbms/jlib
export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib
export TNS_ADMIN=$ORACLE_HOME/network/admin
export SQLPATH=$SQLPATH

export ORACLE_SID=${ORACLE_SID}
#export ORACLE_SID=${ORACLE_SID^^}
$PDBENV
EOF

       if [ "$(which rlwrap 2>/dev/null)" ]
     then cat << EOF >> $HOME/.bashrc
alias sqlplus="rlwrap \$ORACLE_HOME/bin/sqlplus"
alias rman="rlwrap \$ORACLE_HOME/bin/rman"
#alias startdb="sudo $ORADATA/dbconfig/$ORACLE_SID/$INIT_FILE start"
#alias stopdb="sudo $ORADATA/dbconfig/$ORACLE_SID/$INIT_FILE stop"
EOF
     fi

     # Create login.sql
       if [ ! -z "$SQLPATH" ]
     then echo "set pages 9999 lines 200" > $SQLPATH/login.sql
     fi

     runUserScripts $ORACLE_BASE/scripts/setup
fi

# Check database status
HealthCheck
  if [ "$?" -eq 0 ]
then runUserScripts $ORACLE_BASE/scripts/setup
     logger "\n#----------------------------------------------------------#\n"
     logger "  Database $ORACLE_SID is open and available."
     logger "\n#----------------------------------------------------------#\n"
else logger "\n#----------------------------------------------------------#\n"
     warn "  Database setup for $ORACLE_SID was unsuccessful."
     warn "  Check log output for additional information."
     logger "\n#----------------------------------------------------------#\n"
fi

# Tail on alert log and wait (otherwise container will exit)
logger "Tailing alert_${ORACLE_SID}.log:"
tail -f $ORACLE_BASE/diag/rdbms/*/*/trace/alert*.log &
childPID=$!
wait $childPID
