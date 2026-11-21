#include "hexo_native.h"
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static __attribute__((unused)) int64_t arg_int(HxValue *a, int i, const char *what) { if (a[i].tag != HX_INT) hx_raise_error(what); return (int64_t)a[i].payload; }
static __attribute__((unused)) double arg_num(HxValue *a, int i, const char *what) { return hx_to_number(a[i], what); }
static __attribute__((unused)) const char *arg_str(HxValue *a, int i, const char *what) { return hx_to_cstr(a[i], what); }
static __attribute__((unused)) HxValue make_event(const char *name, int key, int x, int y, int button) {
    HxValue e=hx_make_array();hx_array_push(e,hx_make_string(name));hx_array_push(e,HX_INT_VALUE(key));hx_array_push(e,HX_INT_VALUE(x));hx_array_push(e,HX_INT_VALUE(y));hx_array_push(e,HX_INT_VALUE(button));return e;
}
_Noreturn static void game_unavailable(const char *name) {
    char msg[256];snprintf(msg,sizeof(msg),"game.%s requires an SDL2 backend (rebuild with WITH_SDL2=1 and SDL2 development files)",name);hx_raise_error(msg);
}

#ifdef HX_WITH_SDL2
#include <SDL2/SDL.h>
static SDL_Window *hx_sdl_window;
static SDL_Renderer *hx_sdl_renderer;
static int hx_sdl_quit;
static SDL_Color sdl_color(uint32_t rgb) { SDL_Color c={(Uint8)(rgb>>16),(Uint8)(rgb>>8),(Uint8)rgb,(Uint8)(rgb>>24)};if(!(rgb>>24))c.a=255;return c; }
static void sdl_set_color(uint32_t rgb) { SDL_Color c=sdl_color(rgb);SDL_SetRenderDrawColor(hx_sdl_renderer,c.r,c.g,c.b,c.a); }
HX_NATIVE(nat_game_init){(void)fn;if(argc<3||argc>4)hx_raise_error("game.init expects title, width, height and optional flags");if(hx_sdl_window)hx_raise_error("game.init: a window already exists");if(SDL_Init(SDL_INIT_VIDEO|SDL_INIT_AUDIO|SDL_INIT_GAMECONTROLLER)!=0){char m[512];snprintf(m,sizeof(m),"SDL_Init: %s",SDL_GetError());hx_raise_error(m);}Uint32 flags=argc==4?(Uint32)arg_int(args,3,"game flags must be integer"):SDL_WINDOW_RESIZABLE;hx_sdl_window=SDL_CreateWindow(arg_str(args,0,"game title must be string"),SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,(int)arg_int(args,1,"game width must be integer"),(int)arg_int(args,2,"game height must be integer"),flags);if(!hx_sdl_window){char m[512];snprintf(m,sizeof(m),"SDL_CreateWindow: %s",SDL_GetError());hx_raise_error(m);}hx_sdl_renderer=SDL_CreateRenderer(hx_sdl_window,-1,SDL_RENDERER_ACCELERATED|SDL_RENDERER_PRESENTVSYNC);if(!hx_sdl_renderer)hx_sdl_renderer=SDL_CreateRenderer(hx_sdl_window,-1,SDL_RENDERER_SOFTWARE);if(!hx_sdl_renderer){char m[512];snprintf(m,sizeof(m),"SDL_CreateRenderer: %s",SDL_GetError());SDL_DestroyWindow(hx_sdl_window);hx_sdl_window=NULL;hx_raise_error(m);}hx_sdl_quit=0;return HX_BOOL_VALUE(1);}
HX_NATIVE(nat_game_quit){(void)args;(void)fn;if(argc)hx_raise_error("game.quit expects no arguments");if(hx_sdl_renderer)SDL_DestroyRenderer(hx_sdl_renderer);if(hx_sdl_window)SDL_DestroyWindow(hx_sdl_window);hx_sdl_renderer=NULL;hx_sdl_window=NULL;SDL_Quit();hx_sdl_quit=1;return HX_NIL_VALUE;}
HX_NATIVE(nat_game_poll_event){(void)fn;if(argc)hx_raise_error("game.pollEvent expects no arguments");SDL_Event e;if(!SDL_PollEvent(&e))return HX_NIL_VALUE;switch(e.type){case SDL_QUIT:hx_sdl_quit=1;return make_event("quit",0,0,0,0);case SDL_KEYDOWN:return make_event("keyDown",(int)e.key.keysym.sym,0,0,0);case SDL_KEYUP:return make_event("keyUp",(int)e.key.keysym.sym,0,0,0);case SDL_MOUSEMOTION:return make_event("mouseMove",0,e.motion.x,e.motion.y,0);case SDL_MOUSEBUTTONDOWN:return make_event("mouseDown",0,e.button.x,e.button.y,e.button.button);case SDL_MOUSEBUTTONUP:return make_event("mouseUp",0,e.button.x,e.button.y,e.button.button);case SDL_WINDOWEVENT:if(e.window.event==SDL_WINDOWEVENT_SIZE_CHANGED)return make_event("resize",0,e.window.data1,e.window.data2,0);return make_event("window",0,0,0,0);default:return make_event("other",e.type,0,0,0);}}
HX_NATIVE(nat_game_should_close){(void)args;(void)fn;if(argc)hx_raise_error("game.shouldClose expects no arguments");return HX_BOOL_VALUE(hx_sdl_quit);}
HX_NATIVE(nat_game_set_title){(void)fn;if(argc!=1)hx_raise_error("game.setTitle expects a string");if(!hx_sdl_window)hx_raise_error("game window is not initialized");SDL_SetWindowTitle(hx_sdl_window,arg_str(args,0,"game title must be string"));return HX_NIL_VALUE;}
HX_NATIVE(nat_game_clear){(void)fn;if(argc<1||argc>2)hx_raise_error("game.clear expects color and optional alpha");if(!hx_sdl_renderer)hx_raise_error("game renderer is not initialized");uint32_t c=(uint32_t)arg_int(args,0,"color must be integer");if(argc==2)c=(c&0xffffff)|((uint32_t)arg_int(args,1,"alpha must be integer")<<24);sdl_set_color(c);SDL_RenderClear(hx_sdl_renderer);return HX_NIL_VALUE;}
HX_NATIVE(nat_game_present){(void)args;(void)fn;if(argc)hx_raise_error("game.present expects no arguments");if(!hx_sdl_renderer)hx_raise_error("game renderer is not initialized");SDL_RenderPresent(hx_sdl_renderer);return HX_NIL_VALUE;}
HX_NATIVE(nat_game_draw_line){(void)fn;if(argc<5||argc>6)hx_raise_error("game.drawLine expects x1,y1,x2,y2,color and optional alpha");if(!hx_sdl_renderer)hx_raise_error("game renderer is not initialized");uint32_t c=(uint32_t)arg_int(args,4,"color must be integer");if(argc==6)c=(c&0xffffff)|((uint32_t)arg_int(args,5,"alpha must be integer")<<24);sdl_set_color(c);SDL_RenderDrawLine(hx_sdl_renderer,(int)arg_int(args,0,"x must be integer"),(int)arg_int(args,1,"y must be integer"),(int)arg_int(args,2,"x must be integer"),(int)arg_int(args,3,"y must be integer"));return HX_NIL_VALUE;}
HX_NATIVE(nat_game_draw_rect){(void)fn;if(argc<5||argc>6)hx_raise_error("game.drawRect expects x,y,width,height,color and optional filled");if(!hx_sdl_renderer)hx_raise_error("game renderer is not initialized");SDL_Rect r={(int)arg_int(args,0,"x must be integer"),(int)arg_int(args,1,"y must be integer"),(int)arg_int(args,2,"width must be integer"),(int)arg_int(args,3,"height must be integer")};sdl_set_color((uint32_t)arg_int(args,4,"color must be integer"));if(argc==6&&hx_value_truthy(args[5]))SDL_RenderFillRect(hx_sdl_renderer,&r);else SDL_RenderDrawRect(hx_sdl_renderer,&r);return HX_NIL_VALUE;}
HX_NATIVE(nat_game_draw_circle){(void)fn;if(argc<4||argc>5)hx_raise_error("game.drawCircle expects x,y,radius,color and optional filled");if(!hx_sdl_renderer)hx_raise_error("game renderer is not initialized");int cx=(int)arg_int(args,0,"x must be integer"),cy=(int)arg_int(args,1,"y must be integer"),r=(int)arg_int(args,2,"radius must be integer");sdl_set_color((uint32_t)arg_int(args,3,"color must be integer"));int filled=argc==5&&hx_value_truthy(args[4]);for(int y=-r;y<=r;++y){int dx=(int)sqrt((double)r*r-(double)y*y);if(filled)SDL_RenderDrawLine(hx_sdl_renderer,cx-dx,cy+y,cx+dx,cy+y);else{SDL_RenderDrawPoint(hx_sdl_renderer,cx-dx,cy+y);SDL_RenderDrawPoint(hx_sdl_renderer,cx+dx,cy+y);}}return HX_NIL_VALUE;}
HX_NATIVE(nat_game_key_down){(void)fn;if(argc!=1)hx_raise_error("game.keyDown expects a key name");int n=0;const Uint8*k=SDL_GetKeyboardState(&n);SDL_Scancode sc=SDL_GetScancodeFromName(arg_str(args,0,"key name must be string"));if(sc==SDL_SCANCODE_UNKNOWN)return HX_BOOL_VALUE(0);int scan=(int)sc;return HX_BOOL_VALUE(scan>=0&&scan<n&&k[scan]);}
HX_NATIVE(nat_game_mouse){(void)args;(void)fn;if(argc)hx_raise_error("game.mouse expects no arguments");int x=0,y=0;Uint32 b=SDL_GetMouseState(&x,&y);HxValue a=hx_make_array();hx_array_push(a,HX_INT_VALUE(x));hx_array_push(a,HX_INT_VALUE(y));hx_array_push(a,HX_INT_VALUE((b&SDL_BUTTON_LMASK)?1:0));hx_array_push(a,HX_INT_VALUE((b&SDL_BUTTON_RMASK)?1:0));hx_array_push(a,HX_INT_VALUE((b&SDL_BUTTON_MMASK)?1:0));return a;}
HX_NATIVE(nat_game_ticks){(void)args;(void)fn;if(argc)hx_raise_error("game.ticks expects no arguments");return HX_INT_VALUE(SDL_GetTicks64());}
HX_NATIVE(nat_game_delay){(void)fn;if(argc!=1)hx_raise_error("game.delay expects milliseconds");SDL_Delay((Uint32)arg_int(args,0,"milliseconds must be integer"));return HX_NIL_VALUE;}
HX_NATIVE(nat_game_window_size){(void)args;(void)fn;if(argc)hx_raise_error("game.windowSize expects no arguments");if(!hx_sdl_window)hx_raise_error("game window is not initialized");int w,h;SDL_GetWindowSize(hx_sdl_window,&w,&h);HxValue a=hx_make_array();hx_array_push(a,HX_INT_VALUE(w));hx_array_push(a,HX_INT_VALUE(h));return a;}
HX_NATIVE(nat_game_load_bmp){(void)fn;if(argc!=1)hx_raise_error("game.loadBMP expects a file path");if(!hx_sdl_renderer)hx_raise_error("game renderer is not initialized");SDL_Surface *surface=SDL_LoadBMP(arg_str(args,0,"BMP path must be string"));if(!surface){char m[512];snprintf(m,sizeof(m),"game.loadBMP: %s",SDL_GetError());hx_raise_error(m);}SDL_Texture *texture=SDL_CreateTextureFromSurface(hx_sdl_renderer,surface);SDL_FreeSurface(surface);if(!texture){char m[512];snprintf(m,sizeof(m),"game.loadBMP texture: %s",SDL_GetError());hx_raise_error(m);}return HX_INT_VALUE((uintptr_t)texture);}
HX_NATIVE(nat_game_draw_texture){(void)fn;if(argc!=3&&argc!=5)hx_raise_error("game.drawTexture expects texture,x,y and optional width,height");if(!hx_sdl_renderer)hx_raise_error("game renderer is not initialized");if(args[0].tag!=HX_INT||!args[0].payload)hx_raise_error("game texture handle is invalid");SDL_Texture *texture=(SDL_Texture*)(uintptr_t)args[0].payload;int x=(int)arg_int(args,1,"x must be integer"),y=(int)arg_int(args,2,"y must be integer");SDL_Rect dest={x,y,0,0};if(argc==5){dest.w=(int)arg_int(args,3,"width must be integer");dest.h=(int)arg_int(args,4,"height must be integer");}else if(SDL_QueryTexture(texture,NULL,NULL,&dest.w,&dest.h)!=0){char m[512];snprintf(m,sizeof(m),"game.drawTexture: %s",SDL_GetError());hx_raise_error(m);}if(SDL_RenderCopy(hx_sdl_renderer,texture,NULL,&dest)!=0){char m[512];snprintf(m,sizeof(m),"game.drawTexture: %s",SDL_GetError());hx_raise_error(m);}return HX_NIL_VALUE;}
HX_NATIVE(nat_game_destroy_texture){(void)fn;if(argc!=1)hx_raise_error("game.destroyTexture expects texture");if(args[0].tag!=HX_INT||!args[0].payload)hx_raise_error("game texture handle is invalid");SDL_DestroyTexture((SDL_Texture*)(uintptr_t)args[0].payload);return HX_NIL_VALUE;}
HX_NATIVE(nat_game_set_fullscreen){(void)fn;if(argc!=1)hx_raise_error("game.setFullscreen expects enabled boolean");if(!hx_sdl_window)hx_raise_error("game window is not initialized");Uint32 flags=hx_value_truthy(args[0])?SDL_WINDOW_FULLSCREEN_DESKTOP:0;if(SDL_SetWindowFullscreen(hx_sdl_window,flags)!=0){char m[512];snprintf(m,sizeof(m),"game.setFullscreen: %s",SDL_GetError());hx_raise_error(m);}return HX_NIL_VALUE;}
HX_NATIVE(nat_game_controller_count){(void)args;(void)fn;if(argc)hx_raise_error("game.controllerCount expects no arguments");int count=0;for(int i=0;i<SDL_NumJoysticks();++i)if(SDL_IsGameController(i))++count;return HX_INT_VALUE(count);}
HX_NATIVE(nat_game_controller_open){(void)fn;if(argc!=1)hx_raise_error("game.controllerOpen expects a controller ordinal");int ordinal=(int)arg_int(args,0,"controller index must be integer");if(ordinal<0)hx_raise_error("game.controllerOpen: invalid controller index");int device=-1;for(int i=0;i<SDL_NumJoysticks();++i){if(SDL_IsGameController(i)){if(ordinal==0){device=i;break;}--ordinal;}}if(device<0)hx_raise_error("game.controllerOpen: controller index out of range");SDL_GameController *controller=SDL_GameControllerOpen(device);if(!controller){char m[512];snprintf(m,sizeof(m),"game.controllerOpen: %s",SDL_GetError());hx_raise_error(m);}return HX_INT_VALUE((uintptr_t)controller);}
static SDL_GameController *sdl_controller_handle(HxValue v){if(v.tag!=HX_INT||!v.payload)hx_raise_error("game controller handle is invalid or closed");return(SDL_GameController*)(uintptr_t)v.payload;}
HX_NATIVE(nat_game_controller_button){(void)fn;if(argc!=2)hx_raise_error("game.controllerButton expects controller and button index");int button=(int)arg_int(args,1,"controller button must be integer");if(button<0||button>=SDL_CONTROLLER_BUTTON_MAX)hx_raise_error("game.controllerButton: invalid button index");return HX_BOOL_VALUE(SDL_GameControllerGetButton(sdl_controller_handle(args[0]),(SDL_GameControllerButton)button));}
HX_NATIVE(nat_game_controller_axis){(void)fn;if(argc!=2)hx_raise_error("game.controllerAxis expects controller and axis index");int axis=(int)arg_int(args,1,"controller axis must be integer");if(axis<0||axis>=SDL_CONTROLLER_AXIS_MAX)hx_raise_error("game.controllerAxis: invalid axis index");Sint16 value=SDL_GameControllerGetAxis(sdl_controller_handle(args[0]),(SDL_GameControllerAxis)axis);return HX_FLOAT_VALUE(value<0?(double)value/32768.0:(double)value/32767.0);}
HX_NATIVE(nat_game_controller_close){(void)fn;if(argc!=1)hx_raise_error("game.controllerClose expects controller");SDL_GameControllerClose(sdl_controller_handle(args[0]));return HX_NIL_VALUE;}
#else
HX_NATIVE(nat_game_init){(void)args;(void)argc;(void)fn;game_unavailable("init");}
HX_NATIVE(nat_game_quit){(void)args;(void)argc;(void)fn;game_unavailable("quit");}
HX_NATIVE(nat_game_poll_event){(void)args;(void)argc;(void)fn;game_unavailable("pollEvent");}
HX_NATIVE(nat_game_should_close){(void)args;(void)argc;(void)fn;game_unavailable("shouldClose");}
HX_NATIVE(nat_game_set_title){(void)args;(void)argc;(void)fn;game_unavailable("setTitle");}
HX_NATIVE(nat_game_clear){(void)args;(void)argc;(void)fn;game_unavailable("clear");}
HX_NATIVE(nat_game_present){(void)args;(void)argc;(void)fn;game_unavailable("present");}
HX_NATIVE(nat_game_draw_line){(void)args;(void)argc;(void)fn;game_unavailable("drawLine");}
HX_NATIVE(nat_game_draw_rect){(void)args;(void)argc;(void)fn;game_unavailable("drawRect");}
HX_NATIVE(nat_game_draw_circle){(void)args;(void)argc;(void)fn;game_unavailable("drawCircle");}
HX_NATIVE(nat_game_key_down){(void)args;(void)argc;(void)fn;game_unavailable("keyDown");}
HX_NATIVE(nat_game_mouse){(void)args;(void)argc;(void)fn;game_unavailable("mouse");}
HX_NATIVE(nat_game_ticks){(void)args;(void)argc;(void)fn;game_unavailable("ticks");}
HX_NATIVE(nat_game_delay){(void)args;(void)argc;(void)fn;game_unavailable("delay");}
HX_NATIVE(nat_game_window_size){(void)args;(void)argc;(void)fn;game_unavailable("windowSize");}
HX_NATIVE(nat_game_load_bmp){(void)args;(void)argc;(void)fn;game_unavailable("loadBMP");}
HX_NATIVE(nat_game_draw_texture){(void)args;(void)argc;(void)fn;game_unavailable("drawTexture");}
HX_NATIVE(nat_game_destroy_texture){(void)args;(void)argc;(void)fn;game_unavailable("destroyTexture");}
HX_NATIVE(nat_game_set_fullscreen){(void)args;(void)argc;(void)fn;game_unavailable("setFullscreen");}
HX_NATIVE(nat_game_controller_count){(void)args;(void)argc;(void)fn;game_unavailable("controllerCount");}
HX_NATIVE(nat_game_controller_open){(void)args;(void)argc;(void)fn;game_unavailable("controllerOpen");}
HX_NATIVE(nat_game_controller_button){(void)args;(void)argc;(void)fn;game_unavailable("controllerButton");}
HX_NATIVE(nat_game_controller_axis){(void)args;(void)argc;(void)fn;game_unavailable("controllerAxis");}
HX_NATIVE(nat_game_controller_close){(void)args;(void)argc;(void)fn;game_unavailable("controllerClose");}
#endif

_Noreturn static void ray_unavailable(const char *name) { char m[256];snprintf(m,sizeof(m),"%s requires raylib (rebuild with WITH_RAYLIB=1 and raylib development files)",name);hx_raise_error(m); }
#ifdef HX_WITH_RAYLIB
#include <raylib.h>
/* raylib 5.5 renamed the resource checks from *Ready to *Valid.  The
   Makefile probes the installed header instead of guessing from the version
   macros: some packaged raylib releases do not define RAYLIB_VERSION_MAJOR. */
#if defined(HX_RAYLIB_VALID_API) || (defined(RAYLIB_VERSION_MAJOR) && RAYLIB_VERSION_MAJOR >= 6)
#  define HX_RAY_TEXTURE_VALID IsTextureValid
#  define HX_RAY_SOUND_VALID IsSoundValid
#  define HX_RAY_MUSIC_VALID IsMusicValid
#  define HX_RAY_FONT_VALID IsFontValid
#  define HX_RAY_RT_VALID IsRenderTextureValid
#else
#  define HX_RAY_TEXTURE_VALID IsTextureReady
#  define HX_RAY_SOUND_VALID IsSoundReady
#  define HX_RAY_MUSIC_VALID IsMusicReady
#  define HX_RAY_FONT_VALID IsFontReady
#  define HX_RAY_RT_VALID IsRenderTextureReady
#endif
static float ray_pan_value(HxValue value) {
    float pan=(float)arg_num(&value,0,"pan must be numeric");
    if(pan < -1.0f || pan > 1.0f) hx_raise_error("pan must be between -1.0 (left) and 1.0 (right)");
#if !defined(RAYLIB_VERSION_MAJOR) || RAYLIB_VERSION_MAJOR < 6
    pan=(pan+1.0f)*0.5f;  // raylib <= 5.x uses [0, 1], with 0.5 as center
#endif
    return pan;
}
static Color ray_color(HxValue v){if(v.tag!=HX_INT)hx_raise_error("color must be integer 0xRRGGBB or 0xRRGGBBAA");uint32_t c=(uint32_t)v.payload;Color out={(unsigned char)(c>>16),(unsigned char)(c>>8),(unsigned char)c,(unsigned char)((c>>24)?(c>>24):255)};return out;}
static Texture2D *ray_texture(HxValue v){if(v.tag!=HX_INT||!v.payload)hx_raise_error("invalid raylib texture handle");return(Texture2D*)(uintptr_t)v.payload;}
static Font *ray_font_handle(HxValue v){if(v.tag!=HX_INT||!v.payload)hx_raise_error("invalid raylib font handle");return(Font*)(uintptr_t)v.payload;}
static RenderTexture2D *ray_render_texture_handle(HxValue v){if(v.tag!=HX_INT||!v.payload)hx_raise_error("invalid raylib render texture handle");return(RenderTexture2D*)(uintptr_t)v.payload;}
HX_NATIVE(nat_simple_init){(void)fn;if(argc!=3)hx_raise_error("simple_game.initWindow expects width,height,title");InitWindow((int)arg_int(args,0,"width must be integer"),(int)arg_int(args,1,"height must be integer"),arg_str(args,2,"title must be string"));SetExitKey(KEY_NULL);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_close){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.closeWindow expects no arguments");CloseWindow();return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_should_close){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.windowShouldClose expects no arguments");return HX_BOOL_VALUE(WindowShouldClose());}
HX_NATIVE(nat_simple_begin){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.beginDrawing expects no arguments");BeginDrawing();return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_end){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.endDrawing expects no arguments");EndDrawing();return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_clear){(void)fn;if(argc!=1)hx_raise_error("simple_game.clearBackground expects color");ClearBackground(ray_color(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_rect){(void)fn;if(argc<5||argc>6)hx_raise_error("simple_game.drawRectangle expects x,y,width,height,color and optional filled");float x=(float)arg_num(args,0,"x must be number"),y=(float)arg_num(args,1,"y must be number"),w=(float)arg_num(args,2,"width must be number"),h=(float)arg_num(args,3,"height must be number");if(argc==6&&!hx_value_truthy(args[5]))DrawRectangleLines((int)x,(int)y,(int)w,(int)h,ray_color(args[4]));else DrawRectangle((int)x,(int)y,(int)w,(int)h,ray_color(args[4]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_line){(void)fn;if(argc!=5)hx_raise_error("simple_game.drawLine expects x1,y1,x2,y2,color");DrawLine((int)arg_num(args,0,"x1 must be number"),(int)arg_num(args,1,"y1 must be number"),(int)arg_num(args,2,"x2 must be number"),(int)arg_num(args,3,"y2 must be number"),ray_color(args[4]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_circle){(void)fn;if(argc<4||argc>5)hx_raise_error("simple_game.drawCircle expects x,y,radius,color and optional filled");float x=(float)arg_num(args,0,"x must be number"),y=(float)arg_num(args,1,"y must be number"),r=(float)arg_num(args,2,"radius must be number");if(argc==5&&!hx_value_truthy(args[4]))DrawCircleLines((int)x,(int)y,r,ray_color(args[3]));else DrawCircle((int)x,(int)y,r,ray_color(args[3]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_text){(void)fn;if(argc!=5)hx_raise_error("simple_game.drawText expects text,x,y,size,color");DrawText(arg_str(args,0,"text must be string"),(int)arg_int(args,1,"x must be integer"),(int)arg_int(args,2,"y must be integer"),(int)arg_int(args,3,"size must be integer"),ray_color(args[4]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_key_down){(void)fn;if(argc!=1)hx_raise_error("simple_game.isKeyDown expects key code");return HX_BOOL_VALUE(IsKeyDown((int)arg_int(args,0,"key code must be integer")));}
HX_NATIVE(nat_simple_key_pressed){(void)fn;if(argc!=1)hx_raise_error("simple_game.isKeyPressed expects key code");return HX_BOOL_VALUE(IsKeyPressed((int)arg_int(args,0,"key code must be integer")));}
HX_NATIVE(nat_simple_mouse){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.mousePosition expects no arguments");Vector2 p=GetMousePosition();HxValue a=hx_make_array();hx_array_push(a,HX_FLOAT_VALUE(p.x));hx_array_push(a,HX_FLOAT_VALUE(p.y));return a;}
HX_NATIVE(nat_simple_frame_time){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.frameTime expects no arguments");return HX_FLOAT_VALUE(GetFrameTime());}
HX_NATIVE(nat_simple_fps){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.fps expects no arguments");return HX_INT_VALUE(GetFPS());}
HX_NATIVE(nat_simple_target_fps){(void)fn;if(argc!=1)hx_raise_error("simple_game.setTargetFPS expects integer");SetTargetFPS((int)arg_int(args,0,"FPS must be integer"));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_texture_load){(void)fn;if(argc!=1)hx_raise_error("simple_game.loadTexture expects path");Texture2D*t=(Texture2D*)malloc(sizeof(Texture2D));if(!t)hx_raise_error("out of memory");*t=LoadTexture(arg_str(args,0,"texture path must be string"));if(!HX_RAY_TEXTURE_VALID(*t)){free(t);hx_raise_error("raylib could not load texture");}return HX_INT_VALUE((uintptr_t)t);}
HX_NATIVE(nat_simple_texture_draw){(void)fn;if(argc<3||argc>5)hx_raise_error("simple_game.drawTexture expects texture,x,y and optional tint");Texture2D*t=ray_texture(args[0]);Color c=argc==4?ray_color(args[3]):WHITE;DrawTexture(*t,(int)arg_int(args,1,"x must be integer"),(int)arg_int(args,2,"y must be integer"),c);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_texture_unload){(void)fn;if(argc!=1)hx_raise_error("simple_game.unloadTexture expects texture");Texture2D*t=ray_texture(args[0]);UnloadTexture(*t);free(t);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_set_window_title){(void)fn;if(argc!=1)hx_raise_error("simple_game.setWindowTitle expects string");SetWindowTitle(arg_str(args,0,"title must be string"));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_set_fullscreen){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.toggleFullscreen expects no arguments");ToggleFullscreen();return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_mouse_down){(void)fn;if(argc!=1)hx_raise_error("simple_game.isMouseButtonDown expects button");return HX_BOOL_VALUE(IsMouseButtonDown((int)arg_int(args,0,"mouse button must be integer")));}
HX_NATIVE(nat_simple_mouse_pressed){(void)fn;if(argc!=1)hx_raise_error("simple_game.isMouseButtonPressed expects button");return HX_BOOL_VALUE(IsMouseButtonPressed((int)arg_int(args,0,"mouse button must be integer")));}
HX_NATIVE(nat_simple_mouse_wheel){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.mouseWheelMove expects no arguments");return HX_FLOAT_VALUE(GetMouseWheelMove());}
HX_NATIVE(nat_simple_mouse_delta){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.mouseDelta expects no arguments");Vector2 p=GetMouseDelta();HxValue a=hx_make_array();hx_array_push(a,HX_FLOAT_VALUE(p.x));hx_array_push(a,HX_FLOAT_VALUE(p.y));return a;}
HX_NATIVE(nat_simple_key_released){(void)fn;if(argc!=1)hx_raise_error("simple_game.isKeyReleased expects key code");return HX_BOOL_VALUE(IsKeyReleased((int)arg_int(args,0,"key code must be integer")));}
HX_NATIVE(nat_simple_screen_size){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.screenSize expects no arguments");HxValue a=hx_make_array();hx_array_push(a,HX_INT_VALUE(GetScreenWidth()));hx_array_push(a,HX_INT_VALUE(GetScreenHeight()));return a;}
HX_NATIVE(nat_simple_window_size){(void)fn;if(argc!=2)hx_raise_error("simple_game.setWindowSize expects width,height");int w=(int)arg_int(args,0,"width must be integer"),h=(int)arg_int(args,1,"height must be integer");if(w<1||h<1)hx_raise_error("window dimensions must be positive");SetWindowSize(w,h);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_triangle){(void)fn;if(argc!=7)hx_raise_error("simple_game.drawTriangle expects x1,y1,x2,y2,x3,y3,color");Vector2 a={(float)arg_num(args,0,"triangle coordinates must be numeric"),(float)arg_num(args,1,"triangle coordinates must be numeric")};Vector2 b={(float)arg_num(args,2,"triangle coordinates must be numeric"),(float)arg_num(args,3,"triangle coordinates must be numeric")};Vector2 c={(float)arg_num(args,4,"triangle coordinates must be numeric"),(float)arg_num(args,5,"triangle coordinates must be numeric")};DrawTriangle(a,b,c,ray_color(args[6]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_ellipse){(void)fn;if(argc!=5)hx_raise_error("simple_game.drawEllipse expects x,y,radiusX,radiusY,color");DrawEllipse((int)arg_num(args,0,"ellipse coordinates must be numeric"),(int)arg_num(args,1,"ellipse coordinates must be numeric"),(float)arg_num(args,2,"ellipse radius must be numeric"),(float)arg_num(args,3,"ellipse radius must be numeric"),ray_color(args[4]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_line_ex){(void)fn;if(argc!=6)hx_raise_error("simple_game.drawLineEx expects x1,y1,x2,y2,thickness,color");Vector2 a={(float)arg_num(args,0,"line coordinates must be numeric"),(float)arg_num(args,1,"line coordinates must be numeric")};Vector2 b={(float)arg_num(args,2,"line coordinates must be numeric"),(float)arg_num(args,3,"line coordinates must be numeric")};DrawLineEx(a,b,(float)arg_num(args,4,"line thickness must be numeric"),ray_color(args[5]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_rect_rounded){(void)fn;if(argc<6||argc>7)hx_raise_error("simple_game.drawRectangleRounded expects x,y,width,height,roundness,color and optional segments");Rectangle r={(float)arg_num(args,0,"rectangle coordinates must be numeric"),(float)arg_num(args,1,"rectangle coordinates must be numeric"),(float)arg_num(args,2,"rectangle size must be numeric"),(float)arg_num(args,3,"rectangle size must be numeric")};int segments=argc==7?(int)arg_int(args,6,"segments must be integer"):8;DrawRectangleRounded(r,(float)arg_num(args,4,"roundness must be numeric"),segments,ray_color(args[5]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_text_width){(void)fn;if(argc!=2)hx_raise_error("simple_game.measureText expects text and fontSize");return HX_INT_VALUE(MeasureText(arg_str(args,0,"text must be string"),(int)arg_int(args,1,"font size must be integer")));}
HX_NATIVE(nat_simple_begin_2d){(void)fn;if(argc!=6)hx_raise_error("simple_game.beginMode2D expects offsetX,offsetY,targetX,targetY,rotation,zoom");Camera2D c={0};c.offset=(Vector2){(float)arg_num(args,0,"camera values must be numeric"),(float)arg_num(args,1,"camera values must be numeric")};c.target=(Vector2){(float)arg_num(args,2,"camera values must be numeric"),(float)arg_num(args,3,"camera values must be numeric")};c.rotation=(float)arg_num(args,4,"camera rotation must be numeric");c.zoom=(float)arg_num(args,5,"camera zoom must be numeric");BeginMode2D(c);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_end_2d){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.endMode2D expects no arguments");EndMode2D();return HX_NIL_VALUE;}
/* 3D convenience and lower-level functions share the Raylib device backend. */
HX_NATIVE(nat_3d_begin){(void)fn;if(argc!=10)hx_raise_error("game_3d.beginCamera expects position(3), target(3), up(3), fov");Camera3D c={0};c.position=(Vector3){(float)arg_num(args,0,"camera values must be numeric"),(float)arg_num(args,1,"camera values must be numeric"),(float)arg_num(args,2,"camera values must be numeric")};c.target=(Vector3){(float)arg_num(args,3,"camera values must be numeric"),(float)arg_num(args,4,"camera values must be numeric"),(float)arg_num(args,5,"camera values must be numeric")};c.up=(Vector3){(float)arg_num(args,6,"camera values must be numeric"),(float)arg_num(args,7,"camera values must be numeric"),(float)arg_num(args,8,"camera values must be numeric")};c.fovy=(float)arg_num(args,9,"fov must be numeric");c.projection=CAMERA_PERSPECTIVE;BeginMode3D(c);return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_end){(void)args;(void)fn;if(argc)hx_raise_error("game_3d.endCamera expects no arguments");EndMode3D();return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_cube){(void)fn;if(argc!=7)hx_raise_error("game_3d.drawCube expects x,y,z,width,height,depth,color");Vector3 p={(float)arg_num(args,0,"cube coordinates must be numeric"),(float)arg_num(args,1,"cube coordinates must be numeric"),(float)arg_num(args,2,"cube coordinates must be numeric")};Vector3 s={(float)arg_num(args,3,"cube size must be numeric"),(float)arg_num(args,4,"cube size must be numeric"),(float)arg_num(args,5,"cube size must be numeric")};DrawCubeV(p,s,ray_color(args[6]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_sphere){(void)fn;if(argc!=5)hx_raise_error("game_3d.drawSphere expects x,y,z,radius,color");Vector3 p={(float)arg_num(args,0,"sphere position must be numeric"),(float)arg_num(args,1,"sphere position must be numeric"),(float)arg_num(args,2,"sphere position must be numeric")};DrawSphere(p,(float)arg_num(args,3,"radius must be numeric"),ray_color(args[4]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_grid){(void)fn;if(argc<1||argc>2)hx_raise_error("game_3d.drawGrid expects slices and optional spacing");DrawGrid((int)arg_int(args,0,"slices must be integer"),(float)(argc==2?arg_num(args,1,"spacing must be numeric"):1.0));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_plane){(void)fn;if(argc!=6)hx_raise_error("game_3d.drawPlane expects x,y,z,width,length,color");Vector3 p={(float)arg_num(args,0,"plane coordinates must be numeric"),(float)arg_num(args,1,"plane coordinates must be numeric"),(float)arg_num(args,2,"plane coordinates must be numeric")};Vector2 size={(float)arg_num(args,3,"plane size must be numeric"),(float)arg_num(args,4,"plane size must be numeric")};DrawPlane(p,size,ray_color(args[5]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_cube_wires){(void)fn;if(argc!=7)hx_raise_error("game_3d.drawCubeWires expects x,y,z,width,height,depth,color");Vector3 p={(float)arg_num(args,0,"cube coordinates must be numeric"),(float)arg_num(args,1,"cube coordinates must be numeric"),(float)arg_num(args,2,"cube coordinates must be numeric")};Vector3 size={(float)arg_num(args,3,"cube size must be numeric"),(float)arg_num(args,4,"cube size must be numeric"),(float)arg_num(args,5,"cube size must be numeric")};DrawCubeWiresV(p,size,ray_color(args[6]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_sphere_wires){(void)fn;if(argc!=7)hx_raise_error("game_3d.drawSphereWires expects x,y,z,radius,rings,slices,color");Vector3 p={(float)arg_num(args,0,"sphere position must be numeric"),(float)arg_num(args,1,"sphere position must be numeric"),(float)arg_num(args,2,"sphere position must be numeric")};DrawSphereWires(p,(float)arg_num(args,3,"radius must be numeric"),(int)arg_int(args,4,"rings must be integer"),(int)arg_int(args,5,"slices must be integer"),ray_color(args[6]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_cylinder){(void)fn;if(argc!=8)hx_raise_error("game_3d.drawCylinder expects x,y,z,radiusTop,radiusBottom,height,slices,color");Vector3 p={(float)arg_num(args,0,"cylinder position must be numeric"),(float)arg_num(args,1,"cylinder position must be numeric"),(float)arg_num(args,2,"cylinder position must be numeric")};DrawCylinder(p,(float)arg_num(args,3,"radius must be numeric"),(float)arg_num(args,4,"radius must be numeric"),(float)arg_num(args,5,"height must be numeric"),(int)arg_int(args,6,"slices must be integer"),ray_color(args[7]));return HX_NIL_VALUE;}

/* Additional raylib text, render-target and gamepad APIs. */
HX_NATIVE(nat_simple_font_load){(void)fn;if(argc!=1)hx_raise_error("simple_game.loadFont expects path");Font *font=(Font*)malloc(sizeof(Font));if(!font)hx_raise_error("out of memory allocating font handle");*font=LoadFont(arg_str(args,0,"font path must be string"));if(!HX_RAY_FONT_VALID(*font)){free(font);hx_raise_error("raylib could not load font");}return HX_INT_VALUE((uintptr_t)font);}
HX_NATIVE(nat_simple_font_unload){(void)fn;if(argc!=1)hx_raise_error("simple_game.unloadFont expects font");Font *font=ray_font_handle(args[0]);UnloadFont(*font);free(font);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_draw_text_ex){(void)fn;if(argc!=7)hx_raise_error("simple_game.drawTextEx expects font,text,x,y,fontSize,spacing,color");Vector2 position={(float)arg_num(args,2,"text coordinates must be numeric"),(float)arg_num(args,3,"text coordinates must be numeric")};DrawTextEx(*ray_font_handle(args[0]),arg_str(args,1,"text must be string"),position,(float)arg_num(args,4,"font size must be numeric"),(float)arg_num(args,5,"spacing must be numeric"),ray_color(args[6]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_measure_text_ex){(void)fn;if(argc!=4)hx_raise_error("simple_game.measureTextEx expects font,text,fontSize,spacing");Vector2 size=MeasureTextEx(*ray_font_handle(args[0]),arg_str(args,1,"text must be string"),(float)arg_num(args,2,"font size must be numeric"),(float)arg_num(args,3,"spacing must be numeric"));HxValue result=hx_make_array();hx_array_push(result,HX_FLOAT_VALUE(size.x));hx_array_push(result,HX_FLOAT_VALUE(size.y));return result;}
HX_NATIVE(nat_simple_render_texture_load){(void)fn;if(argc!=2)hx_raise_error("simple_game.loadRenderTexture expects width,height");int w=(int)arg_int(args,0,"width must be integer"),h=(int)arg_int(args,1,"height must be integer");if(w<=0||h<=0)hx_raise_error("render texture dimensions must be positive");RenderTexture2D *target=(RenderTexture2D*)malloc(sizeof(RenderTexture2D));if(!target)hx_raise_error("out of memory allocating render texture handle");*target=LoadRenderTexture(w,h);if(!HX_RAY_RT_VALID(*target)){free(target);hx_raise_error("raylib could not create render texture");}return HX_INT_VALUE((uintptr_t)target);}
HX_NATIVE(nat_simple_render_texture_begin){(void)fn;if(argc!=1)hx_raise_error("simple_game.beginTextureMode expects render texture");BeginTextureMode(*ray_render_texture_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_render_texture_end){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.endTextureMode expects no arguments");EndTextureMode();return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_render_texture_draw){(void)fn;if(argc!=3)hx_raise_error("simple_game.drawRenderTexture expects renderTexture,x,y");RenderTexture2D *target=ray_render_texture_handle(args[0]);Rectangle source={0.0f,0.0f,(float)target->texture.width,-(float)target->texture.height};Vector2 position={(float)arg_num(args,1,"x must be numeric"),(float)arg_num(args,2,"y must be numeric")};DrawTextureRec(target->texture,source,position,WHITE);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_render_texture_unload){(void)fn;if(argc!=1)hx_raise_error("simple_game.unloadRenderTexture expects render texture");RenderTexture2D *target=ray_render_texture_handle(args[0]);UnloadRenderTexture(*target);free(target);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_gamepad_available){(void)fn;if(argc!=1)hx_raise_error("simple_game.isGamepadAvailable expects gamepad index");return HX_BOOL_VALUE(IsGamepadAvailable((int)arg_int(args,0,"gamepad index must be integer")));}
HX_NATIVE(nat_simple_gamepad_button){(void)fn;if(argc!=2)hx_raise_error("simple_game.isGamepadButtonDown expects gamepad and button");return HX_BOOL_VALUE(IsGamepadButtonDown((int)arg_int(args,0,"gamepad index must be integer"),(int)arg_int(args,1,"button must be integer")));}
HX_NATIVE(nat_simple_gamepad_pressed){(void)fn;if(argc!=2)hx_raise_error("simple_game.isGamepadButtonPressed expects gamepad and button");return HX_BOOL_VALUE(IsGamepadButtonPressed((int)arg_int(args,0,"gamepad index must be integer"),(int)arg_int(args,1,"button must be integer")));}
HX_NATIVE(nat_simple_gamepad_axis){(void)fn;if(argc!=2)hx_raise_error("simple_game.getGamepadAxisMovement expects gamepad and axis");return HX_FLOAT_VALUE(GetGamepadAxisMovement((int)arg_int(args,0,"gamepad index must be integer"),(int)arg_int(args,1,"axis must be integer")));}
HX_NATIVE(nat_simple_gamepad_name){(void)fn;if(argc!=1)hx_raise_error("simple_game.getGamepadName expects gamepad index");const char *name=GetGamepadName((int)arg_int(args,0,"gamepad index must be integer"));return hx_make_string(name?name:"");}

/* raylib audio resources. Handles own one raylib Sound/Music value. */
static Sound *ray_sound_handle(HxValue v){if(v.tag!=HX_INT||!v.payload)hx_raise_error("simple_game sound handle is invalid or closed");return(Sound*)(uintptr_t)v.payload;}
static Music *ray_music_handle(HxValue v){if(v.tag!=HX_INT||!v.payload)hx_raise_error("simple_game music handle is invalid or closed");return(Music*)(uintptr_t)v.payload;}
static Model *ray_model_handle(HxValue v){if(v.tag!=HX_INT||!v.payload)hx_raise_error("game_3d model handle is invalid or unloaded");return(Model*)(uintptr_t)v.payload;}
HX_NATIVE(nat_simple_audio_init){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.initAudioDevice expects no arguments");InitAudioDevice();if(!IsAudioDeviceReady())hx_raise_error("raylib audio device could not be initialized");return HX_BOOL_VALUE(1);}
HX_NATIVE(nat_simple_audio_close){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.closeAudioDevice expects no arguments");if(IsAudioDeviceReady())CloseAudioDevice();return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_audio_ready){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.audioDeviceReady expects no arguments");return HX_BOOL_VALUE(IsAudioDeviceReady());}
HX_NATIVE(nat_simple_master_volume_set){(void)fn;if(argc!=1)hx_raise_error("simple_game.setMasterVolume expects volume");float volume=(float)arg_num(args,0,"volume must be numeric");if(volume<0.0f||volume>1.0f)hx_raise_error("master volume must be between 0 and 1");SetMasterVolume(volume);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_master_volume_get){(void)args;(void)fn;if(argc)hx_raise_error("simple_game.getMasterVolume expects no arguments");return HX_FLOAT_VALUE(GetMasterVolume());}
HX_NATIVE(nat_simple_sound_load){(void)fn;if(argc!=1)hx_raise_error("simple_game.loadSound expects path");if(!IsAudioDeviceReady())hx_raise_error("call initAudioDevice before loading sounds");Sound *sound=(Sound*)malloc(sizeof(Sound));if(!sound)hx_raise_error("out of memory allocating sound handle");*sound=LoadSound(arg_str(args,0,"sound path must be string"));if(!HX_RAY_SOUND_VALID(*sound)){free(sound);hx_raise_error("raylib could not load sound");}return HX_INT_VALUE((uintptr_t)sound);}
HX_NATIVE(nat_simple_sound_play){(void)fn;if(argc!=1)hx_raise_error("simple_game.playSound expects sound");PlaySound(*ray_sound_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_stop){(void)fn;if(argc!=1)hx_raise_error("simple_game.stopSound expects sound");StopSound(*ray_sound_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_pause){(void)fn;if(argc!=1)hx_raise_error("simple_game.pauseSound expects sound");PauseSound(*ray_sound_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_resume){(void)fn;if(argc!=1)hx_raise_error("simple_game.resumeSound expects sound");ResumeSound(*ray_sound_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_pan){(void)fn;if(argc!=2)hx_raise_error("simple_game.setSoundPan expects sound and pan");SetSoundPan(*ray_sound_handle(args[0]),ray_pan_value(args[1]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_unload){(void)fn;if(argc!=1)hx_raise_error("simple_game.unloadSound expects sound");Sound *sound=ray_sound_handle(args[0]);UnloadSound(*sound);free(sound);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_volume){(void)fn;if(argc!=2)hx_raise_error("simple_game.setSoundVolume expects sound and volume");SetSoundVolume(*ray_sound_handle(args[0]),(float)arg_num(args,1,"volume must be numeric"));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_pitch){(void)fn;if(argc!=2)hx_raise_error("simple_game.setSoundPitch expects sound and pitch");SetSoundPitch(*ray_sound_handle(args[0]),(float)arg_num(args,1,"pitch must be numeric"));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_sound_playing){(void)fn;if(argc!=1)hx_raise_error("simple_game.isSoundPlaying expects sound");return HX_BOOL_VALUE(IsSoundPlaying(*ray_sound_handle(args[0])));}
HX_NATIVE(nat_simple_music_load){(void)fn;if(argc!=1)hx_raise_error("simple_game.loadMusicStream expects path");if(!IsAudioDeviceReady())hx_raise_error("call initAudioDevice before loading music");Music *music=(Music*)malloc(sizeof(Music));if(!music)hx_raise_error("out of memory allocating music handle");*music=LoadMusicStream(arg_str(args,0,"music path must be string"));if(!HX_RAY_MUSIC_VALID(*music)){free(music);hx_raise_error("raylib could not load music");}return HX_INT_VALUE((uintptr_t)music);}
HX_NATIVE(nat_simple_music_play){(void)fn;if(argc!=1)hx_raise_error("simple_game.playMusic expects music");PlayMusicStream(*ray_music_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_update){(void)fn;if(argc!=1)hx_raise_error("simple_game.updateMusic expects music");UpdateMusicStream(*ray_music_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_pause){(void)fn;if(argc!=1)hx_raise_error("simple_game.pauseMusic expects music");PauseMusicStream(*ray_music_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_resume){(void)fn;if(argc!=1)hx_raise_error("simple_game.resumeMusic expects music");ResumeMusicStream(*ray_music_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_stop){(void)fn;if(argc!=1)hx_raise_error("simple_game.stopMusic expects music");StopMusicStream(*ray_music_handle(args[0]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_unload){(void)fn;if(argc!=1)hx_raise_error("simple_game.unloadMusicStream expects music");Music *music=ray_music_handle(args[0]);UnloadMusicStream(*music);free(music);return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_playing){(void)fn;if(argc!=1)hx_raise_error("simple_game.isMusicPlaying expects music");return HX_BOOL_VALUE(IsMusicStreamPlaying(*ray_music_handle(args[0])));}
HX_NATIVE(nat_simple_music_volume){(void)fn;if(argc!=2)hx_raise_error("simple_game.setMusicVolume expects music and volume");SetMusicVolume(*ray_music_handle(args[0]),(float)arg_num(args,1,"volume must be numeric"));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_pitch){(void)fn;if(argc!=2)hx_raise_error("simple_game.setMusicPitch expects music and pitch");SetMusicPitch(*ray_music_handle(args[0]),(float)arg_num(args,1,"pitch must be numeric"));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_pan){(void)fn;if(argc!=2)hx_raise_error("simple_game.setMusicPan expects music and pan");SetMusicPan(*ray_music_handle(args[0]),ray_pan_value(args[1]));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_seek){(void)fn;if(argc!=2)hx_raise_error("simple_game.seekMusicStream expects music and seconds");SeekMusicStream(*ray_music_handle(args[0]),(float)arg_num(args,1,"seconds must be numeric"));return HX_NIL_VALUE;}
HX_NATIVE(nat_simple_music_time){(void)fn;if(argc!=1)hx_raise_error("simple_game.musicTimePlayed expects music");return HX_FLOAT_VALUE(GetMusicTimePlayed(*ray_music_handle(args[0])));}
HX_NATIVE(nat_simple_music_length){(void)fn;if(argc!=1)hx_raise_error("simple_game.musicTimeLength expects music");return HX_FLOAT_VALUE(GetMusicTimeLength(*ray_music_handle(args[0])));}
HX_NATIVE(nat_3d_model_load){(void)fn;if(argc!=1)hx_raise_error("game_3d.loadModel expects path");Model *model=(Model*)malloc(sizeof(Model));if(!model)hx_raise_error("out of memory allocating model handle");*model=LoadModel(arg_str(args,0,"model path must be string"));if(model->meshCount<=0){UnloadModel(*model);free(model);hx_raise_error("raylib could not load model");}return HX_INT_VALUE((uintptr_t)model);}
HX_NATIVE(nat_3d_model_draw){(void)fn;if(argc!=6)hx_raise_error("game_3d.drawModel expects model,x,y,z,scale,color");Vector3 position={(float)arg_num(args,1,"model position must be numeric"),(float)arg_num(args,2,"model position must be numeric"),(float)arg_num(args,3,"model position must be numeric")};DrawModel(*ray_model_handle(args[0]),position,(float)arg_num(args,4,"model scale must be numeric"),ray_color(args[5]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_model_draw_ex){(void)fn;if(argc!=12)hx_raise_error("game_3d.drawModelEx expects model,position(3),axis(3),angle,scale(3),color");Vector3 position={(float)arg_num(args,1,"model position must be numeric"),(float)arg_num(args,2,"model position must be numeric"),(float)arg_num(args,3,"model position must be numeric")};Vector3 axis={(float)arg_num(args,4,"rotation axis must be numeric"),(float)arg_num(args,5,"rotation axis must be numeric"),(float)arg_num(args,6,"rotation axis must be numeric")};Vector3 scale={(float)arg_num(args,8,"model scale must be numeric"),(float)arg_num(args,9,"model scale must be numeric"),(float)arg_num(args,10,"model scale must be numeric")};DrawModelEx(*ray_model_handle(args[0]),position,axis,(float)arg_num(args,7,"rotation angle must be numeric"),scale,ray_color(args[11]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_model_draw_wires){(void)fn;if(argc!=6)hx_raise_error("game_3d.drawModelWires expects model,x,y,z,scale,color");Vector3 position={(float)arg_num(args,1,"model position must be numeric"),(float)arg_num(args,2,"model position must be numeric"),(float)arg_num(args,3,"model position must be numeric")};DrawModelWires(*ray_model_handle(args[0]),position,(float)arg_num(args,4,"model scale must be numeric"),ray_color(args[5]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_model_draw_wires_ex){(void)fn;if(argc!=12)hx_raise_error("game_3d.drawModelWiresEx expects model,position(3),axis(3),angle,scale(3),color");Vector3 position={(float)arg_num(args,1,"model position must be numeric"),(float)arg_num(args,2,"model position must be numeric"),(float)arg_num(args,3,"model position must be numeric")};Vector3 axis={(float)arg_num(args,4,"rotation axis must be numeric"),(float)arg_num(args,5,"rotation axis must be numeric"),(float)arg_num(args,6,"rotation axis must be numeric")};Vector3 scale={(float)arg_num(args,8,"model scale must be numeric"),(float)arg_num(args,9,"model scale must be numeric"),(float)arg_num(args,10,"model scale must be numeric")};DrawModelWiresEx(*ray_model_handle(args[0]),position,axis,(float)arg_num(args,7,"rotation angle must be numeric"),scale,ray_color(args[11]));return HX_NIL_VALUE;}
HX_NATIVE(nat_3d_model_unload){(void)fn;if(argc!=1)hx_raise_error("game_3d.unloadModel expects model");Model *model=ray_model_handle(args[0]);UnloadModel(*model);free(model);return HX_NIL_VALUE;}
#else
#define SIMPLE_STUB(name, label) HX_NATIVE(name){(void)args;(void)argc;(void)fn;ray_unavailable(label);}
SIMPLE_STUB(nat_simple_init,"simple_game.initWindow")
SIMPLE_STUB(nat_simple_close,"simple_game.closeWindow")
SIMPLE_STUB(nat_simple_should_close,"simple_game.windowShouldClose")
SIMPLE_STUB(nat_simple_begin,"simple_game.beginDrawing")
SIMPLE_STUB(nat_simple_end,"simple_game.endDrawing")
SIMPLE_STUB(nat_simple_clear,"simple_game.clearBackground")
SIMPLE_STUB(nat_simple_rect,"simple_game.drawRectangle")
SIMPLE_STUB(nat_simple_line,"simple_game.drawLine")
SIMPLE_STUB(nat_simple_circle,"simple_game.drawCircle")
SIMPLE_STUB(nat_simple_text,"simple_game.drawText")
SIMPLE_STUB(nat_simple_key_down,"simple_game.isKeyDown")
SIMPLE_STUB(nat_simple_key_pressed,"simple_game.isKeyPressed")
SIMPLE_STUB(nat_simple_mouse,"simple_game.mousePosition")
SIMPLE_STUB(nat_simple_frame_time,"simple_game.frameTime")
SIMPLE_STUB(nat_simple_fps,"simple_game.fps")
SIMPLE_STUB(nat_simple_target_fps,"simple_game.setTargetFPS")
SIMPLE_STUB(nat_simple_texture_load,"simple_game.loadTexture")
SIMPLE_STUB(nat_simple_texture_draw,"simple_game.drawTexture")
SIMPLE_STUB(nat_simple_texture_unload,"simple_game.unloadTexture")
SIMPLE_STUB(nat_simple_set_window_title,"simple_game.setWindowTitle")
SIMPLE_STUB(nat_simple_set_fullscreen,"simple_game.toggleFullscreen")
SIMPLE_STUB(nat_simple_mouse_down,"simple_game.isMouseButtonDown")
SIMPLE_STUB(nat_simple_mouse_pressed,"simple_game.isMouseButtonPressed")
SIMPLE_STUB(nat_simple_mouse_wheel,"simple_game.mouseWheelMove")
SIMPLE_STUB(nat_simple_mouse_delta,"simple_game.mouseDelta")
SIMPLE_STUB(nat_simple_key_released,"simple_game.isKeyReleased")
SIMPLE_STUB(nat_simple_screen_size,"simple_game.screenSize")
SIMPLE_STUB(nat_simple_window_size,"simple_game.setWindowSize")
SIMPLE_STUB(nat_simple_triangle,"simple_game.drawTriangle")
SIMPLE_STUB(nat_simple_ellipse,"simple_game.drawEllipse")
SIMPLE_STUB(nat_simple_line_ex,"simple_game.drawLineEx")
SIMPLE_STUB(nat_simple_rect_rounded,"simple_game.drawRectangleRounded")
SIMPLE_STUB(nat_simple_text_width,"simple_game.measureText")
SIMPLE_STUB(nat_simple_begin_2d,"simple_game.beginMode2D")
SIMPLE_STUB(nat_simple_end_2d,"simple_game.endMode2D")
SIMPLE_STUB(nat_3d_begin,"game_3d.beginCamera")
SIMPLE_STUB(nat_3d_end,"game_3d.endCamera")
SIMPLE_STUB(nat_3d_cube,"game_3d.drawCube")
SIMPLE_STUB(nat_3d_sphere,"game_3d.drawSphere")
SIMPLE_STUB(nat_3d_grid,"game_3d.drawGrid")
SIMPLE_STUB(nat_3d_plane,"game_3d.drawPlane")
SIMPLE_STUB(nat_3d_cube_wires,"game_3d.drawCubeWires")
SIMPLE_STUB(nat_3d_sphere_wires,"game_3d.drawSphereWires")
SIMPLE_STUB(nat_3d_cylinder,"game_3d.drawCylinder")
SIMPLE_STUB(nat_simple_audio_init,"simple_game.initAudioDevice")
SIMPLE_STUB(nat_simple_audio_close,"simple_game.closeAudioDevice")
SIMPLE_STUB(nat_simple_audio_ready,"simple_game.audioDeviceReady")
SIMPLE_STUB(nat_simple_master_volume_set,"simple_game.setMasterVolume")
SIMPLE_STUB(nat_simple_master_volume_get,"simple_game.getMasterVolume")
SIMPLE_STUB(nat_simple_font_load,"simple_game.loadFont")
SIMPLE_STUB(nat_simple_font_unload,"simple_game.unloadFont")
SIMPLE_STUB(nat_simple_draw_text_ex,"simple_game.drawTextEx")
SIMPLE_STUB(nat_simple_measure_text_ex,"simple_game.measureTextEx")
SIMPLE_STUB(nat_simple_render_texture_load,"simple_game.loadRenderTexture")
SIMPLE_STUB(nat_simple_render_texture_begin,"simple_game.beginTextureMode")
SIMPLE_STUB(nat_simple_render_texture_end,"simple_game.endTextureMode")
SIMPLE_STUB(nat_simple_render_texture_draw,"simple_game.drawRenderTexture")
SIMPLE_STUB(nat_simple_render_texture_unload,"simple_game.unloadRenderTexture")
SIMPLE_STUB(nat_simple_gamepad_available,"simple_game.isGamepadAvailable")
SIMPLE_STUB(nat_simple_gamepad_button,"simple_game.isGamepadButtonDown")
SIMPLE_STUB(nat_simple_gamepad_pressed,"simple_game.isGamepadButtonPressed")
SIMPLE_STUB(nat_simple_gamepad_axis,"simple_game.getGamepadAxisMovement")
SIMPLE_STUB(nat_simple_gamepad_name,"simple_game.getGamepadName")
SIMPLE_STUB(nat_simple_sound_load,"simple_game.loadSound")
SIMPLE_STUB(nat_simple_sound_play,"simple_game.playSound")
SIMPLE_STUB(nat_simple_sound_stop,"simple_game.stopSound")
SIMPLE_STUB(nat_simple_sound_pause,"simple_game.pauseSound")
SIMPLE_STUB(nat_simple_sound_resume,"simple_game.resumeSound")
SIMPLE_STUB(nat_simple_sound_pan,"simple_game.setSoundPan")
SIMPLE_STUB(nat_simple_sound_unload,"simple_game.unloadSound")
SIMPLE_STUB(nat_simple_sound_volume,"simple_game.setSoundVolume")
SIMPLE_STUB(nat_simple_sound_pitch,"simple_game.setSoundPitch")
SIMPLE_STUB(nat_simple_sound_playing,"simple_game.isSoundPlaying")
SIMPLE_STUB(nat_simple_music_load,"simple_game.loadMusicStream")
SIMPLE_STUB(nat_simple_music_play,"simple_game.playMusic")
SIMPLE_STUB(nat_simple_music_update,"simple_game.updateMusic")
SIMPLE_STUB(nat_simple_music_pause,"simple_game.pauseMusic")
SIMPLE_STUB(nat_simple_music_resume,"simple_game.resumeMusic")
SIMPLE_STUB(nat_simple_music_stop,"simple_game.stopMusic")
SIMPLE_STUB(nat_simple_music_unload,"simple_game.unloadMusicStream")
SIMPLE_STUB(nat_simple_music_playing,"simple_game.isMusicPlaying")
SIMPLE_STUB(nat_simple_music_volume,"simple_game.setMusicVolume")
SIMPLE_STUB(nat_simple_music_pitch,"simple_game.setMusicPitch")
SIMPLE_STUB(nat_simple_music_pan,"simple_game.setMusicPan")
SIMPLE_STUB(nat_simple_music_seek,"simple_game.seekMusicStream")
SIMPLE_STUB(nat_simple_music_time,"simple_game.musicTimePlayed")
SIMPLE_STUB(nat_simple_music_length,"simple_game.musicTimeLength")
SIMPLE_STUB(nat_3d_model_load,"game_3d.loadModel")
SIMPLE_STUB(nat_3d_model_draw,"game_3d.drawModel")
SIMPLE_STUB(nat_3d_model_draw_ex,"game_3d.drawModelEx")
SIMPLE_STUB(nat_3d_model_draw_wires,"game_3d.drawModelWires")
SIMPLE_STUB(nat_3d_model_draw_wires_ex,"game_3d.drawModelWiresEx")
SIMPLE_STUB(nat_3d_model_unload,"game_3d.unloadModel")
#endif

/* Optional compile-time backend diagnostics. */
HX_NATIVE(nat_game_backend) {
    (void)args;(void)fn;if(argc)hx_raise_error("game.backend expects no arguments");
#ifdef HX_WITH_SDL2
    return hx_make_string("SDL2");
#else
    return hx_make_string("unavailable (build with WITH_SDL2=1)");
#endif
}
HX_NATIVE(nat_simple_backend) {
    (void)args;(void)fn;if(argc)hx_raise_error("simple_game.backend expects no arguments");
#ifdef HX_WITH_RAYLIB
    return hx_make_string("raylib");
#else
    return hx_make_string("unavailable (build with WITH_RAYLIB=1)");
#endif
}
