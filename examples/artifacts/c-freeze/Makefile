CC ?= cc
REPO_ROOT := $(abspath ../../..)
TARGET := freeze_client
SRC := freeze_client.c
INCLUDE_DIR := $(REPO_ROOT)/zig-out/include
LIB_DIR := $(REPO_ROOT)/zig-out/lib

CFLAGS ?= -Wall -g
CPPFLAGS += -I$(INCLUDE_DIR)
LDFLAGS += -L$(LIB_DIR) -Wl,-rpath,$(LIB_DIR)
LDLIBS += -lmuxly

.PHONY: all build run play clean

all: build $(TARGET)

build:
	cd $(REPO_ROOT) && zig build example-deps

$(TARGET): $(SRC)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS) $(LDLIBS)

run: all
	./$(TARGET)

play:
	./run.sh

clean:
	rm -f $(TARGET)
