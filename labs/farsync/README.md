# FarSync Lab
This lab automates the build of Data Guard Far Sync through Docker Compose.
# IMPORTANT SETUP INSTRUCTIONS
This lab requires preliminary setup.
## Customize `config-dataguard.lst`
The `config-dataguard.lst` file contains information on each member of the Data Guard configuration. Each member must be present in the file in order:
* The primary database must appear first
* One or more standby databases appear next
* The last member must be the Far Sync
### Notes
* Replace the image name with the database image present on your local system
* The ORACLE_SID must be identical for all members
* The ORACLE_PWD must be identical for all members
* ROLE must be PRIMARY, STANDBY, or FARSYNC
* DG_TARGET
  * On standby databases = the DB_UNQNAME of the PRIMARY
  * On the primary = a comma-delimited list of each standby DB_UNQNAME
  * On the far sync = NULL
* OPEN_MODE
  * Always OPEN for the primary
  * Always MOUNT for the far sync
  * APPLY on the standby will activate managed recovery, otherwise the database will open READ ONLY automatically
## Customize `create_compose.sh`
* Update the value of ORADATA to match the ORADATA directory of your image
* SETUP_DIR is the mount point where the current script directory will be mounted
* The ORADATA directories will be mounted in Docker volumes (FS_${CONTAINER_NAME}). If you would like the volumes bind mounted:
  * Add a generic path (eg, `/somedir/oradata`)
  * Make sure the path exists on the local system
  * On Linux systems, create a subdirectory under this path for each container name (`/somedir/oradata/container_name`) and chown these directories to be owned by `oracle:dba` or `oracle:oinstall`
# Run `create_compose.sh`
Make `create_compose.sh` executable on your system and run it. This will create:
* `docker-compose.yml`: defines all of the services (databases)
* `tnsnames.ora`: a shared file used by all databases
* RMAN scrips to duplicate the database to the standby and far sync members
* Data Guard configurations run from the primary
Modify these scripts as you see fit. They are run automatically when services are initially created.
# Run `docker-compose`
From the current directory, run `docker-compose up -d` to start building the environment. Monitor the build process with `docker-compose logs -f`. The process will:
* Create the database on the primary
* Run RMAN to duplicate the standby and Far Sync databases
* Create the Data Guard Broker configuration
* (Optionally) set the standby to managed apply
# Errata
This is tested in 19c for non-container databases only.
