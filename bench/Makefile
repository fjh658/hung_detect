TINYHOOK_DIR := ../third_party/tinyhook
TINYHOOK_INC := $(TINYHOOK_DIR)/include
TINYHOOK_LIB := $(TINYHOOK_DIR)/build/universal/libtinyhook.a

CC := clang
CFLAGS := -O2 -Wall -mmacosx-version-min=12.0 -I$(TINYHOOK_INC)
LDFLAGS := -dynamiclib -headerpad_max_install_names -framework CoreFoundation -framework IOKit -framework Security

TARGET := libhung_bench.dylib
SRCS := hung_bench.c trampoline.S

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS) $(TINYHOOK_LIB) $(TINYHOOK_INC)/tinyhook.h
	$(CC) $(CFLAGS) $(LDFLAGS) -arch arm64 -arch x86_64 \
		-o $@ $(SRCS) $(TINYHOOK_LIB)

$(TINYHOOK_LIB):
	cd $(TINYHOOK_DIR) && ./build.sh -t macosx -v 12.0

clean:
	rm -f $(TARGET)
