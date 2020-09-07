.PHONY : all
all : liburingraku.so

liburingraku.so :
	gcc -shared -fPIC uraku.c -o liburingraku.so

.PHONY : clean

clean :
	rm liburingraku.so

.PHONY : install
install : liburingraku.so
	cp ./liburingraku.so ../resources/libraries/liburingraku.so

.PHONY : uninstall

uninstall :
	rm ../resources/libraries/liburingraku.so
