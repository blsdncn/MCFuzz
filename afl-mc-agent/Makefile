# Build the JNI shared library for POSIX shared memory attachment
# Usage: make [JAVA_HOME=/path/to/jdk]

JAVA_HOME ?= $(shell readlink -f /usr/bin/java | sed 's:/bin/java::' | sed 's:/jre/bin/java::')

CC = gcc
CFLAGS = -fPIC -O2 -Wall -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/linux
LDFLAGS = -shared

TARGET = libaflmcshm.so
SRC = src/main/native/aflmcshm.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

# Install to a directory on java.library.path (e.g., /usr/local/lib)
install: $(TARGET)
	cp $(TARGET) /usr/local/lib/
	ldconfig
