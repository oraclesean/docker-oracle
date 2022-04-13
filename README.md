# Update
April 13 2022: I'm in the process of updating the documentation to reflect changes to operation/architecture in this repo. Please bear with me as I make these changes!

# docker-oracle
A repository of Docker image builds for creating Oracle databases. This repo replaces the other Docker repos I maintain. 

Jump to a section:
- [Build an image](#build-an-image)
  - [Build options and examples](#build-options-and-examples)
- [Run a container](#run-a-container)
  - [Examples for running Oracle Database containers](#run-options-and-examples)
- [Directory structure](#directory-structure)
  - [Where to put files](#file-placement)
- [Why this Repo](#why-this-repo)
  - [Features](#features)

# Why this Repo
I build and run many Oracle databases in containers. There were things I didn't like about Oracle's build scripts. My goals for this repository are:
- Build any version and any patch level
  - Code should be agnostic
  - Migrate version-specific actions to templates
  - Store versioned information as configurations and manifests
  - Eliminate duplicate assets
  - Flatten and simplify the directory tree
- Streamline builds and reduce image build times
- Allow build- and run-time customization
- Avoid unnecessary environment settings
- Follow Oracle recommendations and best practices
- Support for archive and RPM-based installations
- Leverage buildx/BuildKit capabilities
- Support advanced features and customization:
  - Read-Only Homes
  - CDB and non-CDB database creation
  - For CDB databases, control the number/naming of PDBs
  - Data Guard, Sharding, RAC, GoldenGate, upgrades, etc.

# Build an Image
TODO

# Run a Container
TODO

# Directory Structure
Three subdirectories contain the majority of assets and configuration needed by images.

## `./config`
Here you'll find version-specific files and configuration, including:
- `dbca.<version>.rsp`: Every version of Oracle seems to introduce new options and features for Database Configuration Assistant (DBCA). Each version-specific file includes options with default and placeholder values. During database creation, the script replaces placeholders with values passed to the container at runtime via the `-e` option.
- `inst.<version>.rsp`: The database install response files, like the DBCA response files, include default and placeholder values for customizing database installation for any version of Oracle. The script updates the placeholder values with those present in the Dockerfile or given to the build operation through a `--build-arg` option.
- `manifest.<version>`: The manifest file includes information for all database and/or patch versions:
  ```
  # md5sum                          File name                                Type      Version  Other
  1858bd0d281c60f4ddabd87b1c214a4f  LINUX.X64_193000_db_home.zip             database  19       SE,EE
  #1f86171d22137e31cc2086bf7af36e91  oracle-database-ee-19c-1.0-1.x86_64.rpm  database  19      SE,EE
  b8e1367997544ab2790c5bcbe65ca805  p6880880_190000_Linux-x86-64.zip         opatch    19       6880880
  2a06e8c7409b21de9be6d404d39febda  p30557433_190000_Linux-x86-64.zip        patch     19.6     30557433
  0e0831a46cc3f8312a761212505ba5d1  p30565805_196000DBRU_Linux-x86-64.zip    patch     19.6     30565805
  ...
  5b2f369f6c1f0397c656a5554bc864e6  p33192793_190000_Linux-x86-64.zip        patch     19.13    33192793
  680af566ae1ed41a9916dfb0a122565c  p33457235_1913000DBRU_Linux-x86-64.zip   patch     19.13    33457235
  30eb702fe0c1bee393bb80ff8f10afe9  p33516456_190000_Linux-x86-64.zip        patch     19.13.1  33516456
  de8c41d94676479b9aa35d66ca11c96a  p33457235_1913100DBRUR_Linux-x86-64.zip  patch     19.13.1  33457235
  7bcfdcd0f3086531e232fd0237b7438f  p33515361_190000_Linux-x86-64.zip        patch     19.14    33515361
  ```  

  Column layout:
  - md5sum: The md5sum used for verification/check.
  - File name: Asset file name.
  - Type: Identifies the type of file. Possible values:
    - `database`: A file for installing database software. May be a .zip or .rpm file.
    - `opatch`: The OPatch file for this database version.
    - `patch`: Individual (non-OPatch) patch files.
  - Version: The database version the file applies to. Possible values:
    - database, opatch: The "base version" (in this example, 19).
    - patch: The patch version (eg 19.13 or 19.13.1). When a patch (or version) has multiple files, enter files in apply order, first to last.
  - Other:
    - database: Indicates Edition support.
      - `SE`: Standard Edition, Standard Edition 2
      - `EE`: Enterprise Edition
      - `SE,EE`: All editions
      - `XE`: Express Edition
    - opatch, patch: The patch number.

  Lines beginning with a `#` are ignored as comments.

  In this example, the patch number `33457235` appears twice, once for 19.13 and agains for 19.13.1, but there are version-specific files/checksums.

Additional template files exist in this directory (I will eventually move them to the `template` directory for consistency). There are three categories:
- TNS configurations. Templates for setting up listener and networking configurations. Customize as necessary. During initial database creation, the files are copied to their proper locations and variables interpreted from the environment.
  - `listener.ora.tmpl` 
  - `sqlnet.ora.tmpl`
  - `tnsnames.ora.tmpl`

- Database configuration. Templates used for specialized database creation outside the "normal" automation, currently only used in upgrade images.
  - `init.ora.tmpl`

- Environment configurations. Used to set up the interactive environment in the container. Each has a specific function:
- `env.tmpl`: Used to build `~oracle/.bashrc`. Pay attention to escaping (`\`) on variables, there to support multi-home and multi-SID environments.
- `login.sql.tmpl`: Used to create a `login.sql` file under `$SQLPATH` that formats and customizes SQLPlus output.
- `rlwrap.tmpl`: If `rlwrap` is present in the environment, adds aliases for `sqlplus`, `rman`, and dgmgrl` to the shell.
 
## `./database` and `./database/patches`
**All** database and patch files go here. I redesigned the file structure of this repo in March 2022 to use a common directory for all software. Eliminating versioned subdirectories simplified file management and eliminated file duplication.

I previously supported versioning at the directory and Dockerfile level. It required a 19.13 directory (or a 19c directory and a 19.13 subdirectory), a dedicated Dockerfile, `Dockerfile.19.13`, and a matching docker ignore file, `Dockerfile.19.13.dockerignore`. But all 19c versions use the same .zip/.rpm for installation. `docker build` reads everything in the current directory and its subdirectories into its context prior to performing the build. It doesn't support links. So, to build 19.13 meant I had to have a copy of the 19c base installation media in each subdirectory. Implementation of .dockerignore requires the Dockerfile and its ignore file to have matching names. So, to limit context (preventing `docker build` from reading _every_ file at/below the build directory) I had to have separate, identically-named Dockerfile/.dockerignore files for *every version* I wanted to build.

That duplication was something I set out to to avoid. I switched instead to a dynamic build process that reads context from a common directory, using .dockerignore to narrow its scope. The advantage is having one directory and one copy for all software.

Combining this design with a manifest file means I no longer need to move patches in and out of subdirectories to control the patch level of image builds, nor worry about placing them in numbered folders to manage the apply order. Add the file to the appropriate directory (`database` or `database/patch`) and include an entry in the version manifest.

## `./templates`
Dynamic builds run from the Dockerfile templates in this directory and create two images: a database image and a database-ready Oracle Linux image.

The Oracle Enterprise Linux image, tagged with the database version, includes all database version prerequisites (notably the database preinstall RPM). The same image works for any database version installed atop it, and installing the prereqs (at least on my system) takes longer than installing database software. Rather than duplicating that work, the build looks to see if the image is present and starts there. If not, it builds the OEL image.

Do not be confused by output like this:
```
REPOSITORY    TAG          SIZE
oraclelinux   7-slim-19c   442MB
oraclelinux   7-slim       133MB
oracle/db     19.13.1-EE   7.58GB
```

The total size of these images is not 442MB + 133MB + 7.58GB. Layers in the oraclelinux:7-slim are reused in the oraclelinux:7-slim-19c image, which are reused in the oracle/db:19.13.1-EE image.

The buildDBImage.sh script reads these templates and creates temporary Dockerfiles and dockerignore files, using information in the manifest according to the version (and other information) passed to the script.

# Legacy README:
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
