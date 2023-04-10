DEVICE=root@192.168.31.158
PORT=22

ssh $DEVICE -p $PORT "rm -rf /var/mobile/Documents/Fugu15.tipa"
scp -P$PORT ./Fugu15/Fugu15.tipa $DEVICE:/var/mobile/Documents/Fugu15.tipa
ssh $DEVICE -p $PORT "/var/jb/basebin/jbctl update tipa /var/mobile/Documents/Fugu15.tipa"