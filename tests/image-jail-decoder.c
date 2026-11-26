#include <stdio.h>

static const unsigned char jpeg[] = {
#include "colors.inc"
};

int main(int argc, char **argv)
{
    FILE *output = fopen(argv[argc - 1], "wb");
    if (!output) {
        perror("open decoder output");
        return 1;
    }
    size_t written = fwrite(jpeg, 1, sizeof(jpeg), output);
    int closed = fclose(output);
    return written != sizeof(jpeg) || closed != 0;
}
