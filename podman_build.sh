REPO="1nnoserv:15000/zulip"
IMGNAME="docker-zulip"
IMGTAGS="3.2-0"

buildah bud -t ${IMGNAME}:${IMGTAGS} . \
    && buildah push --tls-verify=false --format=v2s2 ${IMGNAME} docker://${REPO}/${IMGNAME}:${IMGTAGS}