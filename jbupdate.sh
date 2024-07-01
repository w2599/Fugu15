DEVICE=root@iphone12.local
PORT=22
ssh $DEVICE -p $PORT "rm -rf /rootfs/var/mobile/Documents/Dopamine.tipa"
scp -P$PORT -C ./Application/Dopamine.tipa $DEVICE":/rootfs/var/mobile/Documents/Dopamine.tipa"
ssh $DEVICE -p $PORT "/basebin/jbctl update tipa /var/mobile/Documents/Dopamine.tipa"
