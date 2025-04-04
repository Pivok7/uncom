build:
	zig build -Doptimize=ReleaseFast

install: build
	sudo cp zig-out/bin/uncom /usr/local/bin/uncom

uninstall:
	sudo rm /usr/local/bin/uncom

clean:
	rm -rf zig-out
	rm -rf .zig-cache
