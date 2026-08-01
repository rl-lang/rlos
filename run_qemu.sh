qemu-system-x86_64 -kernel bzImage -initrd initramfs.img -append "console=ttyS0 earlyprintk=serial,tty,S0,115200" -nographic -m 512
