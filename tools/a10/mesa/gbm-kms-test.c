// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * The display path a compositor takes on the iPad: GLES (Zink on the A10
 * Vulkan driver) renders through GBM on the GPU's render node, each frame's
 * buffer is exported as a dma-buf, imported into the display device
 * (simpledrm, card0) and scanned out with a framebuffer of it. Draws FRAMES
 * frames (default 120) of a colour cycle with a spinning triangle. Run in the
 * device chroot:
 *
 *   PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 MESA_LOADER_DRIVER_OVERRIDE=zink \
 *       gbm-kms-test [FRAMES]
 *
 * GBM_ON_CARD=1: GBM on the display device instead (what compositors do:
 * Mesa's kmsro pairs simpledrm with Zink on the GPU; run it without
 * MESA_LOADER_DRIVER_OVERRIDE); the scanout buffers are then the display
 * device's own and need no import. GBM_FS_UNIFORM=1: the fragment shader
 * scales the colour by a uniform (a uniform buffer load in the fragment
 * shader, as in Hyprland's shaders). GBM_DRAWS=N: N draws per frame (the
 * triangle rotated a little further each time). GBM_KEEP=1 leaves the last
 * frame on screen for 5 s (for kms-grab).
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static void die(const char *what)
{
	fprintf(stderr, "%s failed (%s)\n", what, strerror(errno));
	exit(1);
}

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok;

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024];

		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		fprintf(stderr, "shader: %s\n", log);
		exit(1);
	}
	return s;
}

int main(int argc, char **argv)
{
	const int frames = argc > 1 ? atoi(argv[1]) : 120;
	int render = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	int card = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	drmModeRes *res;
	drmModeConnector *conn = NULL;
	drmModeModeInfo mode;
	uint32_t crtc, w, h;
	struct gbm_device *gbm;
	struct gbm_surface *surf;
	EGLDisplay dpy;
	EGLConfig cfg;
	EGLContext ctx;
	EGLSurface esurf;
	EGLint n;
	GLuint prog;
	struct timespec t0, t1;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (render < 0 || card < 0)
		die("open");

	/* The display: the first connected connector, its first mode */
	res = drmModeGetResources(card);
	if (!res)
		die("drmModeGetResources");
	for (int i = 0; i < res->count_connectors && !conn; i++) {
		conn = drmModeGetConnector(card, res->connectors[i]);
		if (conn && (conn->connection != DRM_MODE_CONNECTED || !conn->count_modes)) {
			drmModeFreeConnector(conn);
			conn = NULL;
		}
	}
	if (!conn || !res->count_crtcs)
		die("connector");
	mode = conn->modes[0];
	crtc = res->crtcs[0];
	w = mode.hdisplay;
	h = mode.vdisplay;
	printf("display %ux%u\n", w, h);

	/* Rendering: GBM on the render node, EGL + GLES 2 */
	gbm = gbm_create_device(getenv("GBM_ON_CARD") ? card : render);
	if (!gbm)
		die("gbm_create_device");
	surf = gbm_surface_create(gbm, w, h, GBM_FORMAT_XRGB8888,
				  GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR |
					  (getenv("GBM_ON_CARD") ? GBM_BO_USE_SCANOUT : 0));
	if (!surf)
		die("gbm_surface_create");
	dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (!eglInitialize(dpy, NULL, NULL))
		die("eglInitialize");
	eglBindAPI(EGL_OPENGL_ES_API);
	{
		const EGLint attr[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8,
					EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0,
					EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
		EGLConfig cfgs[64];

		eglChooseConfig(dpy, attr, cfgs, 64, &n);
		cfg = NULL;
		for (int i = 0; i < n; i++) {
			EGLint id;

			eglGetConfigAttrib(dpy, cfgs[i], EGL_NATIVE_VISUAL_ID, &id);
			if (id == GBM_FORMAT_XRGB8888) {
				cfg = cfgs[i];
				break;
			}
		}
		if (!cfg)
			die("EGL config");
	}
	{
		const EGLint attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };

		ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, attr);
	}
	esurf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)surf, NULL);
	if (!ctx || esurf == EGL_NO_SURFACE || !eglMakeCurrent(dpy, esurf, esurf, ctx))
		die("EGL context/surface");
	printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));

	prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER,
		"attribute vec2 pos; attribute vec3 col; varying vec3 v;\n"
		"uniform float a;\n"
		"void main() { v = col; gl_Position = vec4(cos(a) * pos.x - sin(a) * pos.y,\n"
		"  sin(a) * pos.x + cos(a) * pos.y, 0.0, 1.0); }\n"));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER, getenv("GBM_FS_UNIFORM") ?
		"precision mediump float; varying vec3 v; uniform float k;\n"
		"void main() { gl_FragColor = vec4(v * v * k, 1.0); }\n" :
		"precision mediump float; varying vec3 v;\n"
		"void main() { gl_FragColor = vec4(v, 1.0); }\n"));
	glBindAttribLocation(prog, 0, "pos");
	glBindAttribLocation(prog, 1, "col");
	glLinkProgram(prog);
	glUseProgram(prog);

	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (int f = 0; f < frames; f++) {
		static const GLfloat pos[] = { -0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.6f };
		static const GLfloat col[] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
		struct gbm_bo *bo;
		uint32_t handle, fb;
		int fd;

		glViewport(0, 0, w, h);
		glClearColor(0.1f + 0.1f * sinf(f * 0.05f), 0.1f, 0.2f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		if (getenv("GBM_FS_UNIFORM"))
			glUniform1f(glGetUniformLocation(prog, "k"), 0.5f + 0.5f * sinf(f * 0.1f));
		glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, pos);
		glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 0, col);
		glEnableVertexAttribArray(0);
		glEnableVertexAttribArray(1);
		for (int d = 0; d < (getenv("GBM_DRAWS") ? atoi(getenv("GBM_DRAWS")) : 1); d++) {
			glUniform1f(glGetUniformLocation(prog, "a"), f * 0.03f + d * 0.2f);
			glDrawArrays(GL_TRIANGLES, 0, 3);
		}
		eglSwapBuffers(dpy, esurf);

		/* Hand the frame to the display device */
		bo = gbm_surface_lock_front_buffer(surf);
		if (getenv("GBM_ON_CARD")) {
			fd = -1;
			handle = gbm_bo_get_handle(bo).u32;
		} else {
			fd = gbm_bo_get_fd(bo);
			if (fd < 0 || drmPrimeFDToHandle(card, fd, &handle))
				die("dma-buf import into the display device");
		}
		{
			uint32_t handles[4] = { handle }, pitches[4] = { gbm_bo_get_stride(bo) },
				 offsets[4] = { 0 };

			if (drmModeAddFB2(card, w, h, DRM_FORMAT_XRGB8888, handles, pitches, offsets,
					  &fb, 0))
				die("drmModeAddFB2");
		}
		if (drmModeSetCrtc(card, crtc, fb, 0, 0, &conn->connector_id, 1, &mode))
			die("drmModeSetCrtc");
		if (f == 0)
			printf("first frame on screen: stride %u, modifier %#llx\n", gbm_bo_get_stride(bo),
			       (unsigned long long)gbm_bo_get_modifier(bo));
		if (f + 1 == frames && getenv("GBM_KEEP"))
			sleep(5);
		drmModeRmFB(card, fb);
		if (fd >= 0)
			close(fd);
		gbm_surface_release_buffer(surf, bo);
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	printf("%d frames in %.2f s: %.1f fps\n", frames,
	       (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9,
	       frames / ((t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9));
	return 0;
}
