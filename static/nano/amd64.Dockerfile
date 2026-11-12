FROM alpine:3.22

# nano, fully static (musl) for the Intel models and the ARM ones, with ncurses built in: Zig compiles both for each
# (with its own musl, laid out for the ARM models' large memory pages), gcc builds ncurses' helper programs for this
# machine, ncurses' tic and terminfo provide the terminal types built in, and QEMU and Python check the ARM build
RUN apk add --no-cache bash binutils-arm-none-eabi build-base file ncurses ncurses-terminfo python3 qemu-arm wget xz zig

# Volume that will point to the whole repository
VOLUME /data

WORKDIR /data
