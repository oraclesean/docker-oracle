ORACLE_BASE_VERSION=${1:-19c}
TAG=${2:-7-slim}
SOURCE=${3:-oraclelinux}

# Set build options
options="--force-rm=true --no-cache=true"

# Set build arguments
arguments="--build-arg SOURCE=$SOURCE --build-arg TAG=$TAG --build-arg ORACLE_BASE_VERSION=$ORACLE_BASE_VERSION"
  if [ -n "$RPM_LIST" ]
then rpm_list="--build-arg RPM_LIST=$RPM_LIST"
fi

# Check whether Docker Build Kit is available; version must be 18.09 or greater.
version=$(docker --version | awk '{print $3}')
major_version=$((10#$(echo $version | cut -d. -f1)))
minor_version=$((10#$(echo $version | cut -d. -f2)))

  if [ "$major_version" -gt 18 ] || [ "$major_version" -eq 18 -a "$minor_version" -gt 9 ]
then BUILDKIT=1
else BUILDKIT=0
fi

# Run the build
DOCKER_BUILDKIT=$BUILDKIT docker build $options $arguments $rpm_list \
                          --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                          -t "$SOURCE":"$TAG"-"$ORACLE_BASE_VERSION" \
                          -f Dockerfile.oraclelinux .
