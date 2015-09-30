#/bin/bash
# start nginx and update nginx.conf
ETCDCTL=/etc/nginx/etcdctl
PARSEJSON=/etc/nginx/parsejson
ENDPOINT=$ETCD_MACHINE
WATCH_KEY=$ETCD_WATCH_KEY
LISTEN_PORT=$NGINX_LISTEN_PORT
DOME_CONF=/etc/nginx/conf.d/dome.conf
SUFFIX=.domerouterdns.local

function get_url() {
    tmp=${1#$WATCH_KEY}
    url=
    while [ ${#tmp} -gt 0 ];
    do
        url=$url.${tmp##*/}
        tmp=${tmp%/*}
    done
    url=${url#*\.}$SUFFIX
    echo $url
}

function put_conf() {
    url=$(get_url $1)
    conf="\nupstream $url {\n"
    args=("$@")
    unset args[0]
    for i in "${args[@]}" ; do
        value=`$ETCDCTL --endpoint=$ENDPOINT get $i`
        host_and_port=`$PARSEJSON "$value"`
        conf=$conf"\tserver $host_and_port;\n"
    done
    conf=$conf"}\n\n"
    conf=$conf"server\n"
    conf=$conf"{\n"
    conf=$conf"\tlisten $LISTEN_PORT;\n"
    conf=$conf"\tserver_name $url;\n"
    conf=$conf"\tlocation / {\n"
    conf=$conf"\t\tproxy_pass http://$url;\n"
    conf=$conf"\t\tproxy_set_header Host \$host;\n"
    conf=$conf"\t\tproxy_set_header X-Real-IP \$remote_addr;\n"
    conf=$conf"\t\tproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
    conf=$conf"\t}\n"
    conf=$conf"}\n"
    echo -e $conf >> $DOME_CONF
}

function create_conf()
{
    echo -e "server {\n\tlisten\t$LISTEN_PORT;\n\tserver_name\tlocalhost;\n}\n" > $DOME_CONF
    keys=(`$ETCDCTL --endpoint=$ENDPOINT ls --sort --recursive -p $WATCH_KEY | grep '[^/]$'`)
    if [ 0 -lt ${#keys[@]} ]; then
        etcds=()
        pre=${keys[0]%/*}
        p=0
        etcds[$p]=${keys[0]}
        let ++p
        cnt=1
        while [ $cnt -lt ${#keys[@]} ];
        do
            tmp=${keys[$cnt]%/*}
            if [ "$tmp"x = "$pre"x ]; then
                etcds[$p]=${keys[$cnt]}
                let ++p
            else
                put_conf "$pre" "${etcds[@]}"
                pre=${keys[$cnt]%/*}
                unset etcds
                p=0
                etcds[$p]=${keys[$cnt]}
                let ++p
            fi
            let ++cnt
        done
        if [ $p -ne 0 ]; then
            put_conf "$pre" "${etcds[@]}"
        fi
    fi
}

create_conf

nginx -g 'daemon off;' -c "/etc/nginx/nginx.conf" &

while true; do
    # watching for change
    $ETCDCTL --endpoint=$ENDPOINT watch --recursive $WATCH_KEY
    # generate new nginx.conf file
    create_conf
    # reload nginx.conf
    nginx -s reload
done

nginx -s stop
