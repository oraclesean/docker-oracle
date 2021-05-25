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
  local __format="$1"
  shift 1

  __line="# ----------------------------------------------------------------------------------------------- #"

    if [[ $__format =~ B ]]
  then printf "\n${__line}\n"
  elif [[ $__format =~ b ]]
  then printf "\n"
  fi

  printf "%s\n" "  $@"

    if [[ $__format =~ A ]]
  then printf "${__line}\n\n"
  elif [[ $__format =~ a ]]
  then printf "\n"
  fi

}

warn() {
  printf "WARNING: %s\n" "$@"
}

error() {
  printf "ERROR: %s\nExiting...\n" "$@"
  return 1
}

debug() {
  __s1=
  __s2=
    if [ "$debug" ]
  then __s1="DEBUG: $1"
       __s2="${2//\n/}" #"$(echo $2 | sed 's/\n//g')"
       printf "%-40s: %s\n" "$__s1" "$__s2" | tee -a "$3"
  fi
}

fixcase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

FIXCASE() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

_sigint() {
  logger BA "${FUNCNAME[0]}: SIGINT recieved: stopping database"
  stopDB
}

_sigterm() {
  logger BA "${FUNCNAME[0]}: SIGTERM received: stopping database"
  stopDB
}

_sigkill() {
  logger BA "${FUNCNAME[0]}: SIGKILL received: Stopping database"
  stopDB
}

replaceVars() {
  local __file="$1"
  local __var="$2"
    if [ -z "$3" ]
  then local __val="$(eval echo \$$(echo $__var))"
  else local __val="$3"
  fi
  sed -i -e "s|###${__var}###|${__val}|g" "$__file"
}

checkDirectory() {
    if [ ! -d "$1" ]
  then error "Directory $1 does not exist"
  elif [ ! -w "$1" ]
  then error "Directory $1 is not writable"
  fi
}

getPreinstall() {
    # Set the default RPM by version:
  case $1 in
       11.*)   pre="oracle-database-preinstall-19c" ;;
       12.1*)  pre="oracle-rdbms-server-12cR1-preinstall tar" ;;
       12.2*)  pre="oracle-database-server-12cR2-preinstall" ;;
       18.*)   pre="oracle-database-preinstall-18c" ;;
       19.*)   pre="oracle-database-preinstall-19c" ;;
       *)      pre="oracle-database-preinstall-19c" ;;
  esac

  export RPM_LIST="openssl $pre $RPM_LIST" 
}

configENV() {
  set -e

  local __min_space_gb=${MIN_SPACE_GB:-12}
  local __target_home=${TARGET_HOME:-$ORACLE_HOME}

    if [ ! "$(df -PB 1G / | tail -n 1 | awk '{print $4}')" -ge "$__min_space_gb" ]
  then error "The build requires at least $__min_space_gb GB free space."
  fi

  getPreinstall "$ORACLE_VERSION"

    if [ -n "$TARGET_HOME" ] && ! [[ $TARGET_HOME == $ORACLE_BASE/* ]]
  then error "The target ORACLE_HOME directory $TARGET_HOME must be a subdirectory of the ORACLE_BASE."
  elif [ -n "$TARGET_HOME" ]
  then getPreinstall "$TARGET_VERSION"
  fi

  yum -y update
  yum -y install $RPM_LIST
  sync

    if [ -n "$RPM_SUPPLEMENT" ]
  then yum -y install $RPM_SUPPLEMENT
  fi

  mkdir -p {"$ORACLE_INV","$ORACLE_HOME","$__target_home","$ORADATA"/{dbconfig,fast_recovery_area},"$ORACLE_BASE"/{admin,scripts/{setup,startup}}} || error "Failure creating directories."
  chown -R oracle:oinstall "$SCRIPTS_DIR" "$ORACLE_INV" "$ORACLE_BASE" "$ORADATA" "$__target_home"                            || error "Failure changing directory ownership."
  ln -s "$ORACLE_BASE"/scripts /docker-entrypoint-initdb.d                                                                    || error "Failure setting Docker entrypoint."
  echo oracle:oracle | chpasswd                                                                                               || error "Failure setting the oracle user password."
  yum clean all
}

checkSum() {
  # $1 is the file name containing the md5 hashes
  # $2 is the extension to check
  grep -E "${2}$" "$1" | while read checksum_value filename
    do
       # md5sum is present and values do not match
         if [ "$(type md5sum 2>/dev/null)" ] && [ ! "$(md5sum "$INSTALL_DIR"/"$filename" | awk '{print $1}')" == "$checksum_value" ]
       then error "Checksum for $filename did not match"
       else # Unzip to the correct directory--ORACLE_HOME for 18c/19c, INSTALL_DIR for others
            case $ORACLE_VERSION in
                 18.*|19.*|21.*) sudo su - oracle -c "unzip -oq -d $ORACLE_HOME $INSTALL_DIR/$filename" ;;
                              *) sudo su - oracle -c "unzip -oq -d $INSTALL_DIR $INSTALL_DIR/$filename" ;;
            esac
       fi
  done
}

installOracle() {
  set -e

  # Default the version and home, use local values to allow multi-home installations
  local __version=${1:-$ORACLE_VERSION}
  local __oracle_home=${2:-$ORACLE_HOME}

    if [ -z "$ORACLE_EDITION" ]
  then error "A database edition is required"
  elif [ "$ORACLE_EDITION" != "EE" ]  && [ "$ORACLE_EDITION" != "SE" ] && [ "$ORACLE_EDITION" != "SE2" ] && [ "$ORACLE_EDITION" != "XE" ]
  then error "Database edition must be one of EE, SE, SE2, or XE"
  elif [ "$__version" == "11.2.0.4" ] && [ "$ORACLE_EDITION" != "EE" ] && [ "$ORACLE_EDITION" != "SE" ]
  then error "Database edition must be EE or SE for version 11.2.0.4"
  elif [ "$__version" == "11.2.0.2" ] && [ "$ORACLE_EDITION" != "XE" ]
  then error "Database edition must be XE for version 11.2.0.2"
  elif [ "$ORACLE_EDITION" == "SE" ]
  then error "Database edition SE is only available for version 11.2.0.4"
  fi

  checkDirectory "$ORACLE_BASE"
  checkDirectory "$__oracle_home"

    if ! [[ $__oracle_home == $ORACLE_BASE/* ]]
  then error "The ORACLE_HOME directory $__oracle_home must be a subdirectory of the ORACLE_BASE."
  fi

   for var in ORACLE_EDITION \
              ORACLE_INV \
              ORACLE_BASE
    do
       replaceVars "$INSTALL_DIR"/"$INSTALL_RESPONSE" "$var"
  done
       replaceVars "$INSTALL_DIR"/"$INSTALL_RESPONSE" "ORACLE_HOME" "$__oracle_home"
#  sed -i -e "s|###ORACLE_EDITION###|$ORACLE_EDITION|g" \
#         -e "s|###ORACLE_INV###|$ORACLE_INV|g" \
#         -e "s|###ORACLE_BASE###|$ORACLE_BASE|g" \
#         -e "s|###ORACLE_HOME###|$__oracle_home|g" "$INSTALL_DIR"/"$INSTALL_RESPONSE"

  # Fix a problem that prevents root from su - oracle:
  sed -i -e "s|\(^session\s*include\s*system-auth\)|#\1|" /etc/pam.d/su

  # Install Oracle binaries
    if [ -f "$(find "$INSTALL_DIR"/ -type f -iregex '.*oracle.*\.rpm.*')" ] || [ -n "$ORACLE_RPM" ]
  then # Install Oracle from RPM
       # The ORACLE_DOCKER_INSTALL environment variable is required for RPM installation to succeed
       export ORACLE_DOCKER_INSTALL=true
         if [ -z "$ORACLE_RPM" ]
       then ORACLE_RPM=$(find "$INSTALL_DIR"/ -type f -iregex '.*oracle.*\.rpm.*')
              if [[ $ORACLE_RPM =~ .*\.zip$ ]]
            then unzip -q "$ORACLE_RPM"
                 ORACLE_RPM=${ORACLE_RPM%.zip}
            fi
       fi

       yum -y localinstall $ORACLE_RPM

       # Determine the name of the init file used for RPM installation
         if [ -z "$INIT_FILE" ]
       then INIT_FILE=$(find /etc/init.d/* -maxdepth 1 -type f -regex '.*/oracle[db_|-xe].*')
       else INIT_FILE=/etc/init.d/"$INIT_FILE"
       fi

       # If different directories are passed to the build, move the directories and recompile.
       OLD_HOME=$(grep -E "^export ORACLE_HOME" "$INIT_FILE" | cut -d= -f2 | tr -d '[:space:]'); export OLD_HOME
       OLD_BASE=$(echo "$OLD_HOME" | sed -e "s|/product.*$||g"); export OLD_BASE
       OLD_INV=$(grep -E "^inventory_loc" "$OLD_HOME"/oraInst.loc | cut -d= -f2); export OLD_INV

         if ! [[ $OLD_BASE -ef $ORACLE_BASE ]] || ! [[ $OLD_HOME -ef $__oracle_home ]] || ! [[ $OLD_INV -ef $ORACLE_INV ]]
       then 
            # Directories cannot be changed in XE. It does not have the ability to relink.
              if [ "$ORACLE_EDITION" == "XE" ] # TODO: clone.pl is deprecated in 19c: -o "$(echo $__version | cut -c 1-2)" == "19"  ]
            then export ORACLE_HOME="$OLD_HOME"
                 export ORACLE_BASE="$OLD_BASE"
                 export ORACLE_INV="$OLD_INV"
            fi

            # Move directories to new locations
              if ! [[ $OLD_INV -ef $ORACLE_INV ]]
            then mv "$OLD_INV"/* "$ORACLE_INV"/ || error "Failed to move Oracle Inventory from $OLD_INV to $ORACLE_INV"
                 find / -name oraInst.loc -exec sed -i -e "s|^inventory_loc=.*$|inventory_loc=$ORACLE_INV|g" {} \;
                 rm -fr $OLD_INV || error "Failed to remove Oracle Inventory from $OLD_INV"
#                  for inv in $(find / -name oraInst.loc)
#                   do sed -i -e "s|^inventory_loc=.*$|inventory_loc=$ORACLE_INV|g" "$inv"
#                 done
            fi

              if ! [[ $OLD_HOME -ef $__oracle_home ]]
            then mv "$OLD_HOME"/* "$__oracle_home"/ || error "Failed to move ORACLE_HOME from $OLD_HOME to $__oracle_home"
                 chown -R oracle:oinstall "$__oracle_home"
                 rm -fr "$OLD_BASE"/product || error "Failed to remove $OLD_HOME after moving to $__oracle_home"
                 sudo su - oracle -c "$__oracle_home/perl/bin/perl $__oracle_home/clone/bin/clone.pl ORACLE_HOME=$__oracle_home ORACLE_BASE=$ORACLE_BASE -defaultHomeName -invPtrLoc $__oracle_home/oraInst.loc" || error "ORACLE_HOME cloning failed for $__oracle_home"
            fi

              if ! [[ $OLD_BASE -ef $ORACLE_BASE ]]
            then rsync -a "$OLD_BASE"/ "$ORACLE_BASE" || error "Failed to move ORACLE_BASE from $OLD_BASE to $ORACLE_BASE"
                 rm -rf $OLD_BASE || error "Failed to remove $OLD_BASE after moving to $ORACLE_BASE"
            fi

#            sed -i -e "s|^export ORACLE_HOME=.*$|export ORACLE_HOME=$__oracle_home|g" \
#                   -e "s|^export TEMPLATE_NAME=.*$|export TEMPLATE_NAME=$INSTALL_TEMPLATE|g" \
#                   -e "s|^CONFIG_NAME=.*$|CONFIG_NAME=\"$INSTALL_RESPONSE\"|g" $INIT_FILE
#            chown -R oracle:oinstall $__oracle_home
#            sed -i -e "s|^inventory_loc=.*$|inventory_loc=$ORACLE_INV|g" $__oracle_home/oraInst.loc
#            sudo su - oracle -c "$__oracle_home/perl/bin/perl $__oracle_home/clone/bin/clone.pl ORACLE_HOME=$__oracle_home ORACLE_BASE=$ORACLE_BASE -defaultHomeName -invPtrLoc $__oracle_home/oraInst.loc"
  	 fi
#       chgrp oinstall $INIT_FILE
#       chgrp oinstall /etc/sysconfig/oracle*

  else # Install Oracle from archive

       # Handle versions with edition-specific installers, which have multiple Checksum files (1 per edition)
       case $(find "$INSTALL_DIR"/Checksum* 2>/dev/null | wc -l) in
         0) unzip -q -d "$INSTALL_DIR" "$INSTALL_DIR"/"*.zip" ;;
         1) checkSum "$INSTALL_DIR"/Checksum zip ;;
         *) checkSum "$INSTALL_DIR"/Checksum."${ORACLE_EDITION}" zip ;;
       esac

       # Unset errors to prevent installer warnings from exiting
       set +e
       # Match the install command to the version
       case $__version in       
            18.*|19.*|21.*) sudo su - oracle -c "$__oracle_home/runInstaller -silent -force -waitforcompletion -responsefile $INSTALL_DIR/$INSTALL_RESPONSE -ignorePrereqFailure" ;;
                         *) sudo su - oracle -c "$INSTALL_DIR/database/runInstaller -silent -force -waitforcompletion -responsefile $INSTALL_DIR/$INSTALL_RESPONSE -ignoresysprereqs -ignoreprereq" ;;
       esac
       set -e

         if [ ! "$("$__oracle_home"/perl/bin/perl -v)" ]
       then mv "$__oracle_home"/perl "$__oracle_home"/perl.old
            curl -o "$INSTALL_DIR"/perl.tar.gz http://www.cpan.org/src/5.0/perl-5.14.1.tar.gz
            tar -xzf "$INSTALL_DIR"/perl.tar.gz
            cd "$INSTALL_DIR"/perl-*
            sudo su - oracle -c "./Configure -des -Dprefix=$__oracle_home/perl -Doptimize=-O3 -Dusethreads -Duseithreads -Duserelocatableinc"
            sudo su - oracle -c "make clean"
            sudo su - oracle -c "make"
            sudo su - oracle -c "make install"

            # Copy old binaries into new Perl directory
            rm -fr "${__oracle_home:?}"/{lib,man}
            cp -r "$__oracle_home"/perl.old/lib/            "$__oracle_home"/perl/
            cp -r "$__oracle_home"/perl.old/man/            "$__oracle_home"/perl/
            cp    "$__oracle_home"/perl.old/bin/dbilogstrip "$__oracle_home"/perl/bin/
            cp    "$__oracle_home"/perl.old/bin/dbiprof     "$__oracle_home"/perl/bin/
            cp    "$__oracle_home"/perl.old/bin/dbiproxy    "$__oracle_home"/perl/bin/
            cp    "$__oracle_home"/perl.old/bin/ora_explain "$__oracle_home"/perl/bin/
            rm -fr "$__oracle_home"/perl.old
            cd "$__oracle_home"/lib
            ln -sf ../javavm/jdk/jdk7/lib/libjavavm12.a
            chown -R oracle:oinstall "$__oracle_home"

            # Relink
            cd "$__oracle_home"/bin
            sudo su - oracle -c "relink all" || echo "Relink failed!"; cat "$__oracle_home/install/relink.log"; exit 1
       fi

  fi

  # Check for OPatch
    if [ "$(find "$INSTALL_DIR" -type f -name "p6880880*.zip" 2>/dev/null)" ]
  then sudo su - oracle -c "unzip -oq -d $__oracle_home $INSTALL_DIR/p6880880*.zip" || error "An incorrect version of OPatch was found (version, architecture or bit mismatch)"
  fi

  # Check for patches
    if [ -d "$INSTALL_DIR/patches" ] 
  then
        for patchdir in $(find "$INSTALL_DIR"/patches/* -type d -regex '.*\/[:digit:].+$' | sed "s|/$||" | sort -n) # | grep -E "[0-9]{3}/" | sed "s|/$||" | sort -n)
         do cd "$patchdir"
              if [ "$(find . -type f -name "*.zip")" ]
            then unzip -q ./*.zip
                 chown -R oracle:oinstall .
                 cd ./*/
                 # Get the apply command from the README
                 opatch_apply=$(grep -E "opatch .apply" README.* | sort | head -1 | awk '{print $2}')
                 opatch_apply=${opatch_apply:-apply}
                 patchdir=$(pwd)
                 # Apply the patch
                 sudo su - oracle -c "$__oracle_home/OPatch/opatch $opatch_apply -silent $patchdir" || error "OPatch $opatch_apply for $patchdir failed"
            fi
       done
  fi

  # Minimize the installation
    if [ -n "$REMOVE_COMPONENTS" ]
  then local __rc=${1^^}

       OLDIFS=$IFS
       IFS=,
        for rc in $__rc
         do
            case $rc in
                 APEX)  # APEX
                        rm -fr "$__oracle_home"/apex 2>/dev/null ;;
                 DBMA)  # Database migration assistant
                        rm -fr "$__oracle_home"/dmu 2>/dev/null ;;
                 DBUA)  # DBUA
                        rm -fr "$__oracle_home"/assistants/dbua 2>/dev/null ;;
                 HELP)  # Help files
                        rm -fr "$__oracle_home"/network/tools/help 2>/dev/null ;;
                 ORDS)  # ORDS
                        rm -fr "$__oracle_home"/ords 2>/dev/null ;;
                 OUI)   # OUI inventory backups
                        rm -fr "$__oracle_home"/inventory/backup/* 2>/dev/null ;;
                 PILOT) # Pilot workflow
                        rm -fr "$__oracle_home"/install/pilot 2>/dev/null ;;
                 SQLD)  # SQL Developer
                        rm -fr "$__oracle_home"/sqldeveloper 2>/dev/null ;;
                 SUP)   # Support tools
                        rm -fr "$__oracle_home"/suptools 2>/dev/null ;;
                 TNS)   # TNS samples
                        rm -fr "$__oracle_home"/network/admin/samples 2>/dev/null ;;
                 UCP)   # UCP
                        rm -fr "$__oracle_home"/ucp 2>/dev/null ;;
                 ZIP)   # Installation files
                        rm -fr "$__oracle_home"/lib/*.zip 2>/dev/null ;;
            esac
       done
       IFS=$OLDIFS
  fi

  # Revert /etc/pam.d/su:
  sed -i -e "s|^\(#\)\(session\s*include\s*system-auth\)|\2|" /etc/pam.d/su
}

runsql() {
  unset spool
    if [ -n "$2" ]
  then spool="spool $2 append"
  fi

  NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
  "$ORACLE_HOME"/bin/sqlplus -S / as sysdba <<EOF
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
    if [ -n "$ORACLE_HOME" ] && [ -n "$ORACLE_SID" ]
  then "$ORACLE_HOME"/bin/lsnrctl start
         if [ -z "$OPEN_MODE" ] || [ "$OPEN_MODE" = "OPEN" ]
       then runsql "startup;"
       else runsql "startup mount;"
            if [ "$OPEN_MODE" != "MOUNT" ]; then runsql "alter database open read only;"; fi
            if [ "$OPEN_MODE"  = "APPLY" ]; then runsql "alter database recover managed standby database disconnect from session;"; fi
       fi
  else error "${FUNCNAME[0]} failed to start the database: ORACLE_HOME and ORACLE_SID must be set."
       return 1
  fi
}

stopDB() {
  runsql "shutdown immediate;"
  "$ORACLE_HOME"/bin/lsnrctl stop
}

checkMode() {
  target_status=$(echo "$1" | sed "s/ /./g")
  check=
  while [[ ! $check =~ $target_status ]]
     do check=$(echo "select open_mode from v\$database;" | "$ORACLE_HOME"/bin/sqlplus -S / as sysdba) 2>/dev/null
          if ! [[ $check =~ $target_status ]]
        then echo "Database $DB_UNQNAME is not online; sleeping."
             sleep 180
        else echo "Database $DB_UNQNAME is online."
        fi
   done
}

setupDG() {
  dbrole=$1 
    if [ "$dbrole" = "PRIMARY" ]
  then "$ORACLE_HOME"/bin/sqlplus / as sysdba @"$SETUP_DIR"/"$SETUP_PRIMARY".sql
        for duplicate in $(find "$SETUP_DIR"/"$RMAN_DUPLICATE".*.rman)
         do cs="$(head -1 "$duplicate" | awk '{print $NF}')"
            "$ORACLE_HOME"/bin/rman target sys/"$ORACLE_PWD"@"$DB_UNQNAME" cmdfile "$duplicate" log /tmp/duplicate.out
            # Open standby database read only
              if [ "$(grep -c farsync "$duplicate")" -eq 0 ]
            then echo "alter database open read only;" | "$ORACLE_HOME"/bin/sqlplus "$cs" as sysdba
            fi
       done
       cat "$SETUP_DIR"/"$BROKER_SCRIPT" | "$ORACLE_HOME"/bin/dgmgrl /
       sleep 60
       cat "$SETUP_DIR"/"$BROKER_CHECKS" | "$ORACLE_HOME"/bin/dgmgrl /
  else mkdir -p "$ORACLE_BASE"/admin/"$DB_UNQNAME"/adump
       mkdir -p "$ORACLE_BASE"/diag/rdbms/"${DB_UNQNAME,,}"/"$ORACLE_SID"/trace
       touch "$ORACLE_BASE"/diag/rdbms/"${DB_UNQNAME,,}"/"$ORACLE_SID"/trace/alert_"$ORACLE_SID".log
       printf "%s:%s:N\n" "$ORACLE_SID" "$ORACLE_HOME" > /etc/oratab
       # Create a pfile for startup of the DG replica
       cat <<- EOF > "$ORACLE_HOME"/dbs/init"$ORACLE_SID".ora
        *.db_name=${ORACLE_SID}
        *.db_unique_name=${DB_UNQNAME}
	*.pga_aggregate_target=10M
	*.sga_target=600M
EOF
       # Create a password file
       "$ORACLE_HOME"/bin/orapwd file="$ORACLE_HOME"/dbs/orapw"$ORACLE_SID" force=yes format=12 <<< $(echo "$ORACLE_PWD")
       echo "startup nomount pfile='${ORACLE_HOME}/dbs/init${ORACLE_SID}.ora';" | "$ORACLE_HOME"/bin/sqlplus / as sysdba
       # Start listener
       "$ORACLE_HOME"/bin/lsnrctl start
       # Wait for the database to come online
         if [ "$OPEN_MODE" = "MOUNT" ]
       then checkMode "MOUNT"
       else checkMode "READ ONLY"
            # Open managed for managed apply
              if [ "$OPEN_MODE" = "APPLY" ]
            then runsql "alter database recover managed standby database disconnect from session;"
            fi
       fi
  fi
}

runDBCA() {
  local __version=$(echo "$ORACLE_VERSION" | cut -d. -f1)
  local __dbcaresponse="$ORACLE_BASE"/dbca."$ORACLE_SID".rsp

  "$ORACLE_HOME"/bin/lsnrctl start
  unset __pdb_only

  # Default init parameters
  local INIT_PARAMS=${INIT_PARAMS:-db_create_file_dest=${ORADATA},db_create_online_log_dest_1=${ORADATA},db_recovery_file_dest=${ORADATA}/fast_recovery_area,audit_trail=none,audit_sys_operations=false}
    if ! [[ $INIT_PARAMS =~ = ]]
  then error "Invalid value provided for INIT_PARAMS: $INIT_PARAMS"
  fi

  # Allow DB unique names:
    if [ -n "$DB_UNQNAME" ] && [ "$DB_UNQNAME" != "$ORACLE_SID" ]
  then __db_msg="$ORACLE_SID with unique name $DB_UNQNAME"
       INIT_PARAMS="${INIT_PARAMS},db_unique_name=$DB_UNQNAME"
  else DB_UNQNAME=$ORACLE_SID
       __db_msg="$ORACLE_SID"
  fi

  logger B "${FUNCNAME[0]}: Running DBCA for database $__db_msg"

  # Additional messages for Data Guard:
    if [ -n "$CONTAINER_NAME" ]; then logger x "${FUNCNAME[0]}:        Container name is: $CONTAINER_NAME"; fi
    if [ -n "$ROLE" ];           then logger x "${FUNCNAME[0]}:        Container role is: $ROLE";           fi
    if [ -n "$DG_TARGET" ];      then logger x "${FUNCNAME[0]}:   Container DG Target is: $DG_TARGET";      fi

  # Detect custom DBCA response files:
  cp "$ORADATA"/dbca."$ORACLE_SID".rsp "$__dbcaresponse" 2>/dev/null || cp "$ORADATA"/dbca.rsp "$__dbcaresponse" 2>/dev/null || cp "$SCRIPTS_DIR"/dbca.rsp "$__dbcaresponse"

    if [ "$__version" != "11" ] && [ -n "$PDB_LIST" ]
  then OLDIFS=$IFS
       IFS=,
       PDB_NUM=1
       PDB_ADMIN=PDBADMIN
        for ORACLE_PDB in $PDB_LIST
         do
            IFS=$OLDIFS
              if [ "$PDB_NUM" -eq 1 ]
            then # Create the database and the first PDB
                 logger A "${FUNCNAME[0]}: Creating container database $__db_msg and pluggable database $ORACLE_PDB"
                 createDatabase "$__dbcaresponse" "$INIT_PARAMS" TRUE 1 "$ORACLE_PDB" "$PDB_ADMIN"
                 PDBENV="export ORACLE_PDB=$ORACLE_PDB"
            else # Create additional PDB
                 logger A "${FUNCNAME[0]}: Creating pluggable database $ORACLE_PDB"
                 createDatabase NONE NONE TRUE 1 "$ORACLE_PDB" "$PDB_ADMIN"
            fi
            addTNSEntry "$ORACLE_PDB"
            PDB_NUM=$((PDB_NUM+1))
            IFS=,
       done
       IFS=$OLDIFS
       alterPluggableDB
  elif [ "$__version" != "11" ] && [ "$PDB_COUNT" -gt 0 ]
  then PDB_ADMIN=PDBADMIN
       logger A "${FUNCNAME[0]}: Creating container database $__db_msg and $PDB_COUNT pluggable database(s) with name $ORACLE_PDB"
       createDatabase "$__dbcaresponse" "$INIT_PARAMS" TRUE "$PDB_COUNT" "$ORACLE_PDB" "$PDB_ADMIN"
         if [ "$PDB_COUNT" -eq 1 ]
       then PDBENV="export ORACLE_PDB=$ORACLE_PDB"
            addTNSEntry "$ORACLE_PDB"
       else PDBENV="export ORACLE_PDB=${ORACLE_PDB}1"
             for ((PDB_NUM=1; PDB_NUM<=PDB_COUNT; PDB_NUM++))
              do addTNSEntry "${ORACLE_PDB}""${PDB_NUM}"
            done
       fi
       alterPluggableDB
  else logger A "${FUNCNAME[0]}: Creating database $__db_msg"
       createDatabase "$__dbcaresponse" "$INIT_PARAMS" FALSE
       PDBENV="unset ORACLE_PDB"
  fi
  logger BA "${FUNCNAME[0]}: DBCA complete"
}

createDatabase() {
  local RESPONSEFILE=$1
  local INIT_PARAMS=$2
  local CREATE_CONTAINER=${3:-TRUE}
  local PDBS=${4:-1}
  local PDB_NAME=${5:-ORCLPDB}
  local PDB_ADMIN=${6:-PDBADMIN}
  local dbcaLogDir=$ORACLE_BASE/cfgtoollogs/dbca

    if [ "$RESPONSEFILE" != "NONE" ]
  then
        for var in ORACLE_BASE \
                   ORACLE_SID \
                   ORACLE_PWD \
                   ORACLE_CHARACTERSET \
                   ORACLE_NLS_CHARACTERSET \
                   CREATE_CONTAINER \
                   ORADATA \
                   PDBS \
                   PDB_NAME \
                   PDB_ADMIN \
                   INIT_PARAMS
         do replaceVars "$RESPONSEFILE" "$var"
            #sed -i -e "s|###${var}###|$(eval echo \$$(echo $var))|g" "$RESPONSEFILE"
       done

       # If there is greater than 8 CPUs default back to dbca memory calculations
       # dbca will automatically pick 40% of available memory for Oracle DB
       # The minimum of 2G is for small environments to guarantee that Oracle has enough memory to function
       # However, bigger environment can and should use more of the available memory
       # This is due to Github Issue #307
         if [ "$(nproc)" -gt 8 ]
       then sed -i -e 's|TOTALMEMORY = "2048"||g' "$RESPONSEFILE"
       fi
       "$ORACLE_HOME"/bin/dbca -silent -createDatabase -responseFile "$RESPONSEFILE" || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$PDB_NAME"/"$DB_UNQNAME".log
  else "$ORACLE_HOME"/bin/dbca -silent -createPluggableDatabase -pdbName "$PDB_NAME" -sourceDB "$ORACLE_SID" -createAsClone true -createPDBFrom DEFAULT -pdbAdminUserName "$PDB_ADMIN" -pdbAdminPassword "$ORACLE_PWD" || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME".log || cat "$dbcaLogDir"/"$DB_UNQNAME"/"$PDB_NAME"/"$DB_UNQNAME".log
  fi

}

moveFiles() {
    if [ ! -d "$ORADATA/dbconfig/$ORACLE_SID" ]
  then mkdir -p "$ORADATA"/dbconfig/"$ORACLE_SID"
  fi

  local __dbconfig="$ORADATA"/dbconfig/"$ORACLE_SID"

   for filename in "$ORACLE_HOME"/dbs/init"$ORACLE_SID".ora \
                   "$ORACLE_HOME"/dbs/spfile"$ORACLE_SID".ora \
                   "$ORACLE_HOME"/dbs/orapw"$ORACLE_SID" \
                   "$ORACLE_HOME"/network/admin/listener.ora \
                   "$ORACLE_HOME"/network/admin/tnsnames.ora \
                   "$ORACLE_HOME"/network/admin/sqlnet.ora
    do
       file=$(basename "$filename")
         if [ -f "$filename" ] && [ ! -f "$__dbconfig/$file" ]
       then mv "$filename" "$__dbconfig"/ 2>/dev/null
       fi
         if [ -f "$__dbconfig/$file" ] && [ ! -L "$filename" ]
       then ln -s "$__dbconfig"/"$file" "$filename" 2>/dev/null
       fi
  done

    if [ -f /etc/oratab ] && [ ! -f "$__dbconfig/oratab" ]
  then cp /etc/oratab "$__dbconfig"/ 2>/dev/null
  fi
  cp "$__dbconfig"/oratab /etc/oratab 2>/dev/null

  # Find wallet subdirectories in dbconfig and relink them:
    if [ -f "$__dbconfig/sqlnet.ora" ]
  then
        for dirname in $(find $__dbconfig -mindepth 1 -type d)
         do dir=$(basename $dirname)
            # Search the sqlnet.ora for an exactly matching subdirectory
            location=$(grep -e "^[^#].*\/$dir\/" $__dbconfig/sqlnet.ora | sed -e "s|^[^/]*/|/|g" -e "s|[^/]*$||")
              if [ -n "$location" ] && [ ! -d "$location" ]
            then # Create the location if it doesn't exist
                 mkdir -p "$location"
            fi
              if [ -d "$location" ] && [ -f "$dirname/*" ]
            then # Move files from the location into the dbconfig directory
                 mv "$location"/* "$dirname"/ 2>/dev/null
            fi
              if [ ! -L "$location" ]
            then # Link files from the dbconfig directory to the location
                 ln -s "$dirname" "$location" 2>/dev/null
            fi
       done
  fi
}

addTNSEntry() {
  ALIAS=$1
  cat << EOF >> "$ORACLE_HOME"/network/admin/tnsnames.ora
${ALIAS} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${CONTAINER_NAME=0.0.0.0})(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${ALIAS})
    )
  )
EOF
}

alterPluggableDB() {
  "$ORACLE_HOME"/bin/sqlplus -S / as sysdba << EOF
alter pluggable database all open;
alter pluggable database all save state;
EOF
}

HealthCheck() {
  local __open_mode="'READ WRITE'"
  local __tabname="v\$database"
  local __pdb_count=${PDB_COUNT:-0}

  source oraenv <<< "$(grep -E "\:${ORACLE_HOME}\:" /etc/oratab | cut -d: -f1 | head -1)" 1>/dev/null
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
  elif [ "$__pdb_count" -gt 0 ] || [ -n "$PDB_LIST" ]
  then __tabname="v\$pdbs"
  fi

  health=$("$ORACLE_HOME"/bin/sqlplus -S / as sysdba << EOF
set head off pages 0 trimspool on feed off serverout on
whenever sqlerror exit warning
--select count(*) from $__tabname where open_mode=$__open_mode;
  select case
         when database_role     = 'PRIMARY'
          and open_mode         = 'READ WRITE'
         then 1
         when database_role  like '%STANDBY'
          and (open_mode     like 'READ ONLY%'
           or  open_mode        = 'MOUNTED')
         then 1
         when database_role     = 'FAR SYNC'
          and open_mode         = 'MOUNTED'
         then 1
         else 0
          end
    from v\$database;
--    from $__tabname;
EOF
)

    if [ "$?" -ne 0 ]
  then return 2
  elif [ "$health" -gt 0 ]
  then return 0
  else return 1
  fi
}

postInstallRoot() {
  # Run root scripts in final build stage
  logger BA "Running root scripts"
  "$ORACLE_INV"/orainstRoot.sh
  "$ORACLE_HOME"/root.sh

  # If this is an upgrade image, run the target root script and attach the new home.
    if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] && [ -f "$TARGET_HOME/root.sh" ]
  then logger BA "Running root script in $TARGET_HOME"
       "$TARGET_HOME"/root.sh
       logger BA "Attaching home for upgrade"
       sudo su - oracle -c "$TARGET_HOME/oui/bin/attachHome.sh"
  fi

  # Additional steps to be performed as root

  # VOLUME_GROUP permits non-oracle/oinstall ownership of bind-mounted volumes. VOLUME_GROUP is passed as GID:GROUP_NAME
    if [ -n "$VOLUME_GROUP" ]
  then local __gid=$(echo "$VOLUME_GROUP" | cut -d: -f1)
       local __grp=$(echo "$VOLUME_GROUP" | cut -d: -f2)
       groupadd -g "$__gid" "$__grp"
       usermod oracle -aG "$__grp"
       chown -R :"$__grp" "$ORADATA"
       chmod -R 775 "$ORADATA"
       chmod -R g+s "$ORADATA"
  fi
}

runUserScripts() {
  local SCRIPTS_ROOT="$1";

    if [ -z "$SCRIPTS_ROOT" ]
  then warn "No script path provided"
       exit 1
  elif [ -d "$SCRIPTS_ROOT" ] && [ -n "$(ls -A "$SCRIPTS_ROOT")" ]
  then # Check that directory exists and it contains files
       logger B "${FUNCNAME[0]}: Running user scripts"
        for f in "$SCRIPTS_ROOT"/*
         do
            case "$f" in
                 *.sh)     logger ba "${FUNCNAME[0]}: Script: $f"; . "$f" ;;
                 *.sql)    logger ba "${FUNCNAME[0]}: Script: $f"; echo "exit" | "$ORACLE_HOME"/bin/sqlplus -s "/ as sysdba" @"$f" ;;
                 *)        logger ba "${FUNCNAME[0]}: Ignored file $f" ;;
            esac
       done

       logger A "${FUNCNAME[0]}: User scripts complete"
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
while getopts ":ehOPRU" opt; do
      case ${opt} in
           h) # Check health of the database
              HealthCheck || exit 1
              exit 0 ;;
           e) # Configure environment
              configENV
              exit 0 ;;
           O) # Install Oracle
              installOracle "$ORACLE_VERSION" "$ORACLE_HOME"
              exit 0 ;;
           P) # Change passwords
              # TODO: Get the password from the CLI
              changePassword
              exit 0 ;;
           R) # Post install root scripts
              postInstallRoot
              exit 0 ;;
           U) # Install Oracle upgrade home
              installOracle "$TARGET_VERSION" "$TARGET_HOME"
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

  if [ "${#__mem}" -lt 11 ] && [ "$__mem" -lt 2147483648 ]
then error "The database container requires at least 2GB of memory; only $__mem is available"
fi

  if [ "$(hostname | grep -Ec "_")" -gt 0 ]
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

# Check the audit path
  if [ ! -d "$ORACLE_BASE"/admin/"$ORACLE_SID"/adump ]
then mkdir -p "$ORACLE_BASE"/admin/"$ORACLE_SID"/adump
fi

# Check whether database already exists
  if [ "$(grep -Ec "^$ORACLE_SID\:" /etc/oratab)" -eq 1 ] && [ -d "$ORADATA"/"${ORACLE_SID^^}" ] || [ -d "$ORADATA"/"${ORACLE_SID}" ]
then moveFiles
     startDB 
else # Create the TNS configuration
     mkdir -p "$ORACLE_HOME"/network/admin 2>/dev/null
     echo "NAME.DIRECTORY_PATH=(TNSNAMES, EZCONNECT, HOSTNAME)" > "$ORACLE_HOME"/network/admin/sqlnet.ora

     cat << EOF > "$ORACLE_HOME"/network/admin/listener.ora
LISTENER = 
  (DESCRIPTION_LIST = 
    (DESCRIPTION = 
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1)) 
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${CONTAINER_NAME=0.0.0.0})(PORT = 1521)) 
    ) 
  ) 

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${DB_UNQNAME-$ORACLE_SID})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${ORACLE_SID})
    )
  )

DEDICATED_THROUGH_BROKER_LISTENER=ON
DIAG_ADR_ENABLED = off
EOF

       if [ -f "$SETUP_DIR"/tnsnames.ora ]
     then cp "$SETUP_DIR"/tnsnames.ora "$ORACLE_HOME"/network/admin/tnsnames.ora
     else echo "$ORACLE_SID=localhost:1521/$ORACLE_SID" > "$ORACLE_HOME"/network/admin/tnsnames.ora
     fi

     # Create a database password if none exists
       if [ -z "$ORACLE_PWD" ]
     then ORACLE_PWD=$(openssl rand -base64 8)1; export ORACLE_PWD
          logger BA "${FUNCNAME[0]}: ORACLE PASSWORD FOR SYS, SYSTEM AND PDBADMIN: $ORACLE_PWD"
     fi

     # Create the user profile
    cat << EOF >> "$HOME"/.bashrc
export PS1="[\u - \\\${ORACLE_SID}] \w\n# "

export ORACLE_BASE=${ORACLE_BASE}
export ORACLE_HOME=${ORACLE_HOME}
export PATH=${ORACLE_HOME}/bin:${ORACLE_HOME}/OPatch/:/usr/sbin:${PATH} 
export CLASSPATH=${ORACLE_HOME}/jlib:${ORACLE_HOME}/rdbms/jlib
export LD_LIBRARY_PATH=${ORACLE_HOME}/lib:/usr/lib
export TNS_ADMIN=${ORACLE_HOME}/network/admin
export ORACLE_PATH=${ORACLE_PATH}

export ORACLE_SID=${ORACLE_SID}
#export ORACLE_SID=${ORACLE_SID^^}
${PDBENV}
EOF

       if [ "$(rlwrap -v)" ]
     then cat << EOF >> "$HOME"/.bashrc
alias sqlplus="rlwrap \$ORACLE_HOME/bin/sqlplus"
alias rman="rlwrap \$ORACLE_HOME/bin/rman"
alias dgmgrl="rlwrap \$ORACLE_HOME/bin/dgmgrl"
EOF
     fi > /dev/null 2>&1

     # Create login.sql
       if [ -n "$ORACLE_PATH" ]
     then echo "set pages 9999 lines 200" > "$ORACLE_PATH"/login.sql
     fi

     # Run DBCA if this is a standalone database or primary in a Data Guard configuration
       if [ -z "$ROLE" ]
     then runDBCA
     elif [ "$ROLE" = "PRIMARY" ]
     then runDBCA
          setupDG "$ROLE"
     else setupDG "$ROLE"
     fi

     moveFiles
     runUserScripts "$ORACLE_BASE"/scripts/setup
fi

# Check database status
  if HealthCheck
#  if [ "$?" -eq 0 ]
then runUserScripts "$ORACLE_BASE"/scripts/setup
       if [ -n "$DB_UNQNAME" ]
     then msg="$ORACLE_SID with unique name $DB_UNQNAME"
     else msg="$ORACLE_SID"
     fi
# TODO: Report the correct open mode
     logger BA "Database $msg is open and available."
else warn "Database setup for $ORACLE_SID was unsuccessful."
     warn "Check log output for additional information."
fi

# Tail on alert log and wait (otherwise container will exit)
logger B "Tailing alert_${ORACLE_SID}.log:"
tail -f "$ORACLE_BASE"/diag/rdbms/*/*/trace/alert*.log &
childPID=$!
wait $childPID
