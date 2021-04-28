#!/bin/bash
set -ex

THIS="$(dirname "$(readlink -f "$0")")"
echo "Script dir: ${THIS}"

function finish {
  # show current container info to re-access after exit with error
  echo "Exit: ${B}"
}
trap finish EXIT

REPO="1nnoserv:15000/zulip"
IMGNAME="docker-zulip"
IMGTAGS="3.2-ppenguin"

BIMGNAME="zulip-builder"
BASEIMG="ubuntu:18.04"

BUILD=${THIS}/.build
DEBAR=${THIS}/.apt-archives

prep_dirs() {
    [[ -d "${DEBAR}" ]] || mkdir -p "${DEBAR}"
    [[ -d "${BUILD}" ]] \
        && rm -rf ${BUILD}/zulip ${BUILD}/zulip-server-docker \
        || mkdir -p "${BUILD}" 
}

prep_tsearch() {
    cd ${BUILD}
    [[ -d dictionaries ]] || git clone https://github.com/wooorm/dictionaries.git
    [[ -d tsearch_data ]] || mkdir tsearch_data
    iconv -f ISO_8859-1 -t UTF-8 dictionaries/dictionaries/en/index.dic > tsearch_data/en_us.dict
    iconv -f ISO_8859-1 -t UTF-8 dictionaries/dictionaries/en/index.aff > tsearch_data/en_us.affix
}

stage1() {
    set -ex

    [[ -n "$(buildah list | grep "${BIMGNAME}")" ]] && buildah rm ${BIMGNAME}

    C=$(buildah from --name ${BIMGNAME} ${BASEIMG})
    buildah config \
        --env LANG="C.UTF-8" \
        --env ZULIP_GIT_URL="https://github.com/zulip/zulip.git" \
        --env ZULIP_GIT_REF=3.2 \
        --env CUSTOM_CA_CERTIFICATES="" \
        ${C}

    # buildah tag "${REPO}/${DOCKER_IMAGE}" $c

    B="buildah run --tty -v ${THIS}:/buildahdir -v ${BUILD}:/build -v ${DEBAR}:/var/cache/apt/archives ${C}"
    # now we can simply invoke all steps by prepending b to a normal shell command in the build env

    echo "Building ${BIMGNAME} using build container ${C}"

    ${B} /bin/bash <<"BASHBUILDAH"
set -ex

{ [ ! "$UBUNTU_MIRROR" ] || sed -i "s|http://\(\w*\.\)*archive\.ubuntu\.com/ubuntu/\? |$UBUNTU_MIRROR |" /etc/apt/sources.list; } \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && DEBIAN_FRONTEND=noninteractive \
    apt-get -q install --no-install-recommends -y ca-certificates git locales lsb-release python3 sudo tzdata

useradd -d /home/zulip -m zulip \
    && echo 'zulip ALL=(ALL:ALL) NOPASSWD:ALL' >> /etc/sudoers

su -p - zulip

# because we preserved the env we need to override the user's home
export HOME=/home/zulip
cd /home/zulip

git clone "$ZULIP_GIT_URL" \
    && cd zulip \
    && git checkout -b current "$ZULIP_GIT_REF"

# Finally, we provision the development environment and build a release tarball
./tools/provision --build-release-tarball-only
. /srv/zulip-py3-venv/bin/activate \
    && ./tools/build-release-tarball docker \
    && sudo mv /tmp/tmp.*/zulip-server-docker.tar.gz /build/zulip-server-docker.tar.gz

echo "build container finished."
BASHBUILDAH

}


stage2() {
    set -ex
    ## now build final container
    [[ -n "$(buildah list | grep "${IMGNAME}")" ]] && buildah rm ${IMGNAME}

    C=$(buildah from --name ${IMGNAME} ${BASEIMG})
    buildah config \
        --env DATA_DIR="/data" \
        --env CUSTOM_CA_CERTIFICATES="" \
        --volume "/data" \
        --port 80 \
        --port 443 \
        --entrypoint '["/sbin/entrypoint.sh"]' \
        --cmd "app:run" \
        ${C}

    B="buildah run --tty -v ${THIS}:/buildahdir -v ${BUILD}:/build -v ${DEBAR}:/var/cache/apt/archives $C"

    echo "Building ${IMGNAME} using build container ${C}"

# added some options to install:
#   --postgresql-missing-dictionaries (https://zulip.readthedocs.io/en/latest/production/deployment.html?highlight=postgres-missing-dictionaries#step-1-set-up-zulip)
#       (does this obsolete our tsearch hack?)
#   --postgresql-version=13 (just in case, see https://zulip.readthedocs.io/en/latest/production/install-existing-server.html?highlight=postgres%20port#postgresql)
# oh, apparently these are not valid options... So what about the docs?
${B} /bin/bash <<"BASHBUILDAH"
set -ex

{ [ ! "$UBUNTU_MIRROR" ] || sed -i "s|http://\(\w*\.\)*archive\.ubuntu\.com/ubuntu/\? |$UBUNTU_MIRROR |" /etc/apt/sources.list; } \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && DEBIAN_FRONTEND=noninteractive \
    apt-get -q install --no-install-recommends -y ca-certificates locales lsb-release python3 sudo tzdata nginx

useradd -d /home/zulip -m zulip \
    && echo 'zulip ALL=(ALL:ALL) NOPASSWD:ALL' >> /etc/sudoers

# Make sure Nginx is started by Supervisor.
dpkg-divert --add --rename /etc/init.d/nginx && \
ln -s /bin/true /etc/init.d/nginx && \
mkdir -p "$DATA_DIR"

cd /build && \
tar -xf zulip-server-docker.tar.gz \
&& mv zulip-server-docker zulip \
&& cd zulip \
&& cp -rf /buildahdir/custom_zulip_files/* . \
&& export PUPPET_CLASSES="zulip::dockervoyager" \
        DEPLOYMENT_TYPE="dockervoyager" \
        ADDITIONAL_PACKAGES="expect" \
&& ./scripts/setup/install \
    --hostname="$(hostname)" \
    --email="docker-zulip" \
    --no-init-db \
&& rm -f /etc/zulip/zulip-secrets.conf /etc/zulip/settings.py \
&& apt-get -qq autoremove --purge -y \
&& apt-get -qq clean \
&& rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# apparently necessary if using a "normal" external pgsql server to avoid errors during init
mkdir -p /usr/share/postgresql/12/
cp -r /build/tsearch_data /usr/share/postgresql/12/
cp /buildahdir/entrypoint.sh /sbin/entrypoint.sh
cp /buildahdir/certbot-deploy-hook /sbin/certbot-deploy-hook
ln -sf /home/zulip/deployments/next /root/zulip
# chown -R zulip /home/zulip

echo "build container finished."
BASHBUILDAH

    # reconfigure to remove temporary mounts
    buildah config \
        -v ${THIS}:/buildahdir- \
        -v ${BUILD}:/build- \
        -v ${DEBAR}:/var/cache/apt/archives- \
        ${C}
}

bcommit() {
    set -ex
    buildah commit --format=docker --tls-verify=false ${1} ${2}
}

# bpush <imgname> <imgurl>
bpush() {
    set -ex
    buildah push --tls-verify=false --format=v2s2 ${1} ${2}
}


# setup one-time
prep_dirs
prep_tsearch

# build first stage
# stage1 \
#    && bcommit ${C} ${BIMGNAME}

# build second stage
stage2 \
   && bcommit ${C} ${IMGNAME} \
   && bpush ${IMGNAME} docker://${REPO}/${IMGNAME}:${IMGTAGS}