# Note
I added major feature updates to this repository on March 3 2022; usage information below may be out-of-date. I will update this README with revised information shortly. SS
# docker-oracle
A repository of Docker image builds for creating Oracle databases. This repo replaces the other Docker repos I maintain. There were things I didn't like about the generally available build scripts that I wanted to improve on.
## Use ARG Over ENV
Assigning build-specific variables as ARG instead of ENV means only variables necessary for the runtime environment are visible. Artifacts of the build process aren't passed to the container environmnent, reducing clutter and making it less obvious that this is a container.
## Limit Duplication
I was tired of tweaking and managing multiple scripts for one version and then having to copy that change everywhere else. I'd rather have one master script for each activity—install Oracle, create a database, apply a patch, etc.—and manage version-specific exceptions there, than deal with multiple, nearly identical scripts under each version's subdirectory. It reduces duplication and redundant code, and makes it easier to manage and test changes.  

There is one script to handle all operations, for all editions and versions. This adds some complexity to the script (it has to accommodate peculiarities of every version and edition) but:
- _For the most part_ these operations are identical across the board
- One script in the root directory does everything and only one script needs maintenance
- Version differences are all in one place vs. hidden in multiple files in parallel directories

The `/opt/scripts/manageOracle.sh` script manages all Oracle/Docker operations, from build through installation:
- Configures the environment
- Installs RPM
- Installs the database
- Creates the database
- Starts and stops the database
- Performs health checks
## Limit Version-Specific Content
There are separate Dockerfiles and subdirectories for each version. I treat the Dockerfiles as configurations and use one script to read and apply the configurations, instead of maintaining version-specific scripts.  

The Dockerfiles are nearly identical; in fact, building _any version or edition_ of an Oracle database can be handled with a single Dockerfile by passing version-specific ARGs in the `build`. The reason I use separate Dockerfiles (Dockerfile.${VERSION}) is because of a limitation in Docker itself.  

When running a (native) build, Docker scans the directory tree for files. If there are install and patch files in each of the version subdirectories, the context grows too large. The files and directories that Docker scans can be limited by using a `.dockerignore` file, but... there's only one `.dockerignore` and there's no option for specifying the ignore file. Building different versions requires changing the ignore file.  

Using a buildkit and specifying a Dockerfile with a non-default name causes Docker to look for and respect ignore files with the same name as the Dockerfile that add the `.dockerignore` suffix. In this way, multiple (versioned) Dockerfiles allow custom ignore files that pass only context needed by the version.  
### Version Directory Structure
Each version has a subdirectory tree such as:  
```
${VERSION}
└── install
    ├── Checksum
    ├── oracle-${VERSION}-${EDITION}.conf
    ├── dbca.rsp
    ├── inst.rsp
    ├── DATABASE.zip
    ├── DATABASE.rpm
    ├── p6880880_*.zip
    └── patches
        ├── 001
        │   └── patch1.zip
        └── 002
            └── patch2.zip
```
- `Checksum`: md5 hash and file names for the database install and/or RPM files.
- `oracle-${VERSION}-${EDITION}.conf`: RPM install configuration required for 11g and 18c XE installations.
- `dbca.rsp`: Template response file for DBCA.
- `inst.rsp`: Template response file for `runInstall`.
- `DATABASE.zip` and/or `DATABASE.rpm`: Database installers. If an `.rpm` file is present, the RPM installation is used.
- `p6880880_*.zip`: (Optional) OPatch file applied directly to `ORACLE_HOME`.
- `patches/*`: (Optional) Subdirectories containing patch archives to be applied during database installation, one patch per subdirectory.
## Base Linux Image Creation
Instead of duplicating the time and effort spent building base images—that is, pulling a Linux image and adding database prerequisite packages—for each build, the `buildLinuxImage.sh` script takes the database version (11g, 12.1, 12.2, 18c, 19c, 21c) and applies the prerequisite package, along with any additional custom RPMs and tags the result as `REPOSITORY:TAG-ORACLE_VERSION`.
Run the script as:
```
./buildLinuxImage.sh ORACLE_BASE_VERSION [TAG] [REPOSITORY]
```
Where:
- `ORACLE_BASE_VERSION` is one of 11g, 12.1, 12.2, 18c, 19c, or 21c
- `TAG` (optional) is the reposotiry tag. Defaults to `7-slim`
- `REPOSITORY` (optional) is the name of the repository (Linux distro). Defaults to `oraclelinux`
## Flexible Image Creation
Each Dockerfile uses a set of common ARG values. Defaults are set in each Dockerfile but can be overridden by passing `--build-arg` values to `docker build`. This allows a single Dockerfile to accommodate a wide range of build options without changes to any files, including:
- Removing specific components (APEX, SQL Developer, help files, etc) to minimize image size without editing scripts. It's easier to build images to include components that are normally be deleted. This is particularly useful for building images for testing 19c upgrades. APEX is included in the seed database but older APEX schemas have to be removed prior to a 19c upgrade. Where's the removal script? In the APEX directory, among those commonly removed to trim image size!
- Add programs/binaries at build time as variables, rather than in a script. Hey, sometimes you want editors or `strace` or `git`, sometimes you don't. Set the defaults to your preferred set of binaries. Override them at build time as necessary, again without having to edit/revert any files.
- Some database versions may require special RPM. Rather than maintaining that in scripts, it's in the Dockerfile (configuration).
- Add supplemental RPMs. Some RPM have dependencies (such as `rlwrap`) that require a second execution of `rpm install`. All builds treat this the same way.
  - The RPM list includes tools for interactive use of containers. 
  - Remove `git`, `less`, `strace`, `tree`, `vi`, `which`, and `bash-completion` for non-interactive environments
  - `sudo` is used to run installations from the `manageOracle.sh` script
- All builds are multi-stage with identical steps, users and operations. Differences are handled by the management script by reading configuration information from the Dockerfile, discovered in the file structure, or set in the environment.
- Customizing the directories for `ORACLE_BASE`, `ORACLE_HOME`, `oraInventory`, and the `oradata` directory.
- Specify Read-Only Oracle Home (ROOH). Set `ROOH=ENABLE` in the Dockerfile, or pass `--build-arg ROOH=ENABLE` during build.
## Install Oracle from Archive (ZIP) or RPM
RPM builds operate a little differently. They have a dependency on `root` because database configuration and startup is managed through `/etc/init.d`. The configuration is in `/etc/sysconfig`. If left at their default (I have a repo for building default RPM-based Oracle installations elsewhere) they need `root` and pose a security risk. I experimented with workarounds (adding `oracle` to `sudoers`, changing the `/etc/init.d` script group to `oinstall`, etc) but RPM-created databases still ran differently.   

I use the RPM to create the Oracle software home, then discard what's in `/etc/init.d` and `/etc/sysconfig` and create and start the database "normally" using DBCA and SQLPlus.  

This allows additional options for RPM-based installations, including changing the directory structure (for non-18c XE installs—the 18c XE home does not include libraries needed to recompile) and managing configuration through the same mechanism as "traditional" installations, meaning anything that can be applied to a "normal" install can be set in a RPM-based installation, without editing a different set of files in `/etc/sysconfig` and `ORACLE_HOME`. Express Edition on 18c (18.4) can be extended to use:
- Custom SID (not stuck with XE)
- Container or non-container
- Custom PDB name(s)
- Multiple PDB
## Flexible Container Creation
I wanted images capable of running highly customizable database environments out of the gate, that mimic what's seen in real deployments. This includes running non-CDB databases, multiple pluggable databases, case-sensitive SID and PDB names, and custom PDB naming (to name a few). Database creation is controlled and customized by passing environment variables to `docker run` via `-e VARIABLE=VALUE`. Notable options include:
- `PDB_COUNT`: Create non-container databases by setting this value to 0, or set the number of pluggable databases to be spawned.
- `CREATE_CONTAINER`: Ture/false, an alternate method for creating a non-CDB database.
- `ORACLE_PDB`: This is the prefix for the PDB's (when PDB_COUNT > 1) or the PDB_NAME (when PDB_COUNT=1, the default).
- `DB_UNQNAME`: Set the database Unique Name. Default is ORACLE_SID; used mainly for creating containers used for Data Guard where the database and unique names are different, and avoids generating multiple diagnostic directory trees.
- `PDB_LIST`: A comma-delimited list of PDB names. When present, overrides the PDB_COUNT and ORACLE_PDB values.
- `ORACLE_CHARACTERSET` and `ORACLE_NLS_CHARACTERSET`: Set database character sets.
- `INIT_PARAMS`: A list of parameters to set in the database at creation time. The default sets the DB_CREATE_FILE_DEST, DB_CREATE_ONLINE_LOG_DEST_1, and DB_RECOVERY_FILE_DEST to $ORADATA (enabling OMF) and turns off auditing.
## DEBUG mode
Debug image builds, container creation, or container operation. 
- Use `--build-arg DEBUG="bash -x"` to debug image builds
- Use `-e DEBUG="bash -x"` to debug container creation
- Use `export DEBUG="bash -x"` to turn on debugging output in a running container
- Use `unset DEBUG` to turn debugging off in a running container
# Examples
Create a non-container database:  
`docker run -d -e PDB_COUNT=0 IMG_NAME`  
Create a container database with custom SID and PDB name:  
`docker run -d -e ORACLE_SID=mysid -e ORACLE_PDB=mypdb IMG_NAME`  
Create a container database with a default SID and three PDB named mypdb[1,2,3]:  
`docker run -d -e PDB_COUNT=3 -e ORACLE_PDB=mypdb IMG_NAME`  
Create a container database with custom SID and named PDB:  
`docker run -d -e ORACLE_SID=mydb -e PDB_LIST="test,dev,prod" IMG_NAME`
# Errata
## ORACLE_PDB Behavior in Containers
There are multiple mechanisms that set the ORACLE_PDB variable in a container. It is set explicitly by passing a value (e.g. `-e ORACLE_PDB=value`) during `docker run`. This is the preferred way of doing things since it correctly sets the environment.
The value may be set implicitly four ways:
- If ORACLE_PDB is not set and the database version requires a PDB (20c and later), the value of ORACLE_PDB is inherited from the image.
- If ORACLE_PDB is not set and PDB_COUNT is non-zero, PDB_COUNT PDBs are implied. The value of ORACLE_PDB is inherited from the image.
- If both ORACLE_PDB and PDB_COUNT are set, ORACLE_PDB is assumed to be a prefix. PDB_COUNT pluggable databases are created as ${ORACLE_PDB}1 through ${ORACLE_PDB}${PDB_COUNT}. ORACLE_PDB in this case is not an actual pluggable database but a prefix.
- If ORACLE_PDB is not set and PDB_LIST contains one or more values, ORACLE_PDB is inherited from the image.
In each case the ORACLE_PDB environment variable is added to the `oracle` user's login scripts. Run that request more than one PDB (PDB_LIST, PDB_COUNT > 1) set the default value to the first PDB in the list/${ORACLE_PDB}1.
In these latter cases, the ORACLE_PDB for interactive sessions is set by login but non-interactive sessions *DO NOT* get the local value. They inherit the value from the container's native environment.
Take the following examples:
- `docker run ... -e ORACLE_PDB=PDB ...`: The interactive and non-interactive values of ORACLE_PDB match.
- 'docker run ... -e PDB_COUNT=n ...`: The interactive value of ORACLE_PDB is ORCLPDB1. The non-interactive value is ORCLPDB. This happens because the inherited value, ORCLPDB is used for non-interactive sessions.
- `docker run ... -e PDB_LIST=PDB1,MYPDB ...`: The interactive value of ORACLE_PDB is PDB1. The non-interactive value is ORCLPDB (see above).
- `docker run ... ` a 21c database: The interactive value of ORACLE_PDB is set in the DBCA scripts as ORCLPDB. The non-interactive value equals whatever is set in the Dockerfile. 
This can cause confusion when calling scripts. For example:
```
docker exec -it CON_NAME bash
env | grep ORACLE_PDB
exit
```
...will show the correct, expected value. However:
```
docker exec -it CON_NAME bash -c "env | grep ORACLE_PDB"
```
...may show a different value. This is expected (and intended and desirable—it's necessary for statelessness and idempotency) but may lead to confusion.
I recommend handling this as follows:
- Set ORACLE_PDB explicitly in `docker run` even when using PDB_LIST. PDB_LIST is evaluated first so setting ORACLE_PDB sets the environment and PDB_LIST creates multiple pluggable databases. The default PDB should be first in the list and match ORACLE_PDB.
- If you need multiple PDBs, use PDB_LIST instead of PDB_COUNT, and set ORACLE_PDB to the "default" PDB. Otherwise, the ORACLE_PDB value in non-interactive shells is the prefix and not a full/valid PDB name.
# TODO
- Remove sudo option for building containers. It's only used during software installation and isn't required in final images.
# Glossary
- APEX: Oracle Application Express, a low-code web development tool.
- CDB: Container Database - Introduced in 12c, container databases introduce capacity and security enhancements. Each CDB consists of a root container plus one or more Pluggable Databases, or PDBs.
- DBCA: Oracle Database Configuration Assistant - a tool for creating databases.
- EE: Oracle Enterprise Edition - A licensed, more robust version of Oracle that can be extended through addition of add-ons like Advanced Compression, Partitioning, etc.
- ORACLE_BASE: The base directory for Oracle software installation.
- ORACLE_HOME: The directory path containing an Oracle database software installation.
- ORACLE_INVENTORY, Oracle Inventory: Metadata of Oracle database installations on a host.
- PDB: Pluggable Database - One or more PDBs "plug in" to a container database.
- RPM: RedHat Package Manager - package files for installing software on Linux.
- runInstall: Performs Oracle database software installation.
- SE, SE2: Oracle Standard Edition/Oracle Standard Edition 2 - A licensed version of Oracle with limited features. Not all features are available, licensed, or extensive in SE/SE2. For example, partitioning is not available in SE/SE2, and RAC is limited to specific node/core counts.
- XE: Oracle Express Edition - A limited version of the Oracle database that is free to use.
