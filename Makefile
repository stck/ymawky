ymawky: FORCE
	cc -c ymawky.S -o ymawky.o
	cc -c file.S -o file.o
	ld ymawky.o file.o -o ymawky -l System -syslibroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -e _main -arch arm64
	make clean

FORCE:

clean:
	-rm ymawky.o file.o

clean-exe:
	-rm ymawky

clean-all:
	-make clean
	-make clean-exe

all:
	make clean
	make ymawky
