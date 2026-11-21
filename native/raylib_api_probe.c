/* Compile-only feature probe for raylib 5.5+ resource validation API. */
#include <raylib.h>

int main(void)
{
    Texture2D texture = {0};
    Sound sound = {0};
    Music music = {0};
    Font font = {0};
    RenderTexture2D target = {0};

    (void)IsTextureValid(texture);
    (void)IsSoundValid(sound);
    (void)IsMusicValid(music);
    (void)IsFontValid(font);
    (void)IsRenderTextureValid(target);
    return 0;
}
