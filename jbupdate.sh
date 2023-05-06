DEVICE=root@192.168.31.158
PORT=22

ssh $DEVICE -p $PORT "rm -rf /var/mobile/Documents/Dopamine.tipa"
scp -P$PORT ./Dopamine/Dopamine.tipa $DEVICE:/var/mobile/Documents/Dopamine.tipa
ssh $DEVICE -p $PORT "/var/jb/basebin/jbctl update tipa /var/mobile/Documents/Dopamine.tipa"