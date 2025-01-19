 set -e
 for server in eu1 eu2 us1 us2 as1 as2; do
     echo "Updating $server"
     git push $server master --tags
     echo "Waiting 60 seconds..."
     sleep 300
 done
