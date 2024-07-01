DEVICE=root@iphone.local
PORT=22
ssh $DEVICE -p $PORT "rm -rf /rootfs/var/mobile/Documents/basebin.tar"
scp -P$PORT -C ./basebin.tar $DEVICE":/rootfs/var/mobile/Documents/basebin.tar"
ssh $DEVICE -p $PORT "/basebin/jbctl update basebin /var/mobile/Documents/basebin.tar"
