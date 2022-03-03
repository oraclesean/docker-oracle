FROM ###FROM_OEL_BASE### as db

# DB installation defaults
ARG MANAGE_ORACLE=manageOracle.sh
ARG SCRIPTS_DIR=/opt/scripts
ARG INSTALL_DIR=/opt/install
ARG ORACLE_VERSION=###ORACLE_VERSION###
ARG INSTALL_RESPONSE=inst.###INSTALL_RESPONSE_ARG###.rsp
###ORACLE_RPM_ARG###
ARG REMOVE_COMPONENTS="DBMA,HELP,ORDS,OUI,PATCH,PILOT,SQLD,SUP,UCP,TCP,ZIP"

# Copy DB install files
COPY $MANAGE_ORACLE $SCRIPTS_DIR/
COPY --chown=oracle:oinstall ./config/* $INSTALL_DIR/
COPY --chown=oracle:oinstall ./database/ $INSTALL_DIR

# Install DB software binaries
RUN chmod ug+x $SCRIPTS_DIR/$MANAGE_ORACLE && \
     bash -x $SCRIPTS_DIR/$MANAGE_ORACLE -O
#    $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE -O

FROM ###FROM_OEL_BASE###

USER oracle
COPY --chown=oracle:oinstall ./config/* $INSTALL_DIR/
COPY --chown=oracle:oinstall --from=db $ORACLE_INV  $ORACLE_INV
COPY --chown=oracle:oinstall --from=db $ORACLE_BASE $ORACLE_BASE
COPY --chown=oracle:oinstall --from=db $ORADATA     $ORADATA

USER root
RUN $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE -R

USER oracle
WORKDIR /home/oracle

VOLUME ["$ORADATA"]
EXPOSE 1521 5500 8080
HEALTHCHECK --interval=1m --start-period=5m CMD $SCRIPTS_DIR/$MANAGE_ORACLE -h >/dev/null || exit 1
CMD exec $DEBUG $SCRIPTS_DIR/$MANAGE_ORACLE
