// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Vulkan render test: a triangle with per-vertex colours into a B8G8R8A8
 * image (64x64, TRI_SIZE=WxH) with dynamic rendering, cleared to TRI_CLEAR
 * (default dark blue). The image memory is mapped and read twiddled (Morton
 * order, y bit first, over the power-of-two padded size: how the A10 stores
 * render targets) or, with TRI_LINEAR=1, linear at the driver's row pitch,
 * then checked: the clear colour outside the triangle, red/green/blue near
 * its corners. TRI_NODRAW=1 renders the clear only. TRI_FB=/dev/fb0 copies
 * the result row by row to a framebuffer device (the iPad's screen with
 * TRI_SIZE=1536x2048). TRI_TEX=1 samples a 4x4 RGBA8 texture at the vertex
 * colour's (r, g) instead (texel (x, y) = (0x80, 0x40 y, 0x40 x), filled
 * twiddled from the CPU); TRI_TEX=linear with a linear-tiled texture,
 * TRI_FILTER=linear with a linear filter, TRI_WRAP=repeat repeating past the
 * edges (TRI_VCOL places the sample); TRI_TEX_SIZE=WxH a W x H texture of
 * (0x80, y, x) gradients instead (x and y scaled to 0-255).
 *
 * Shader tests: TRI_FS_SPV=FILE takes the fragment shader from a SPIR-V
 * file (TRI_VS_SPV the vertex shader: inputs vec2 position, vec4 colour),
 * TRI_VCOL=R,G,B,A gives every vertex that colour (uniform inputs the
 * compiler cannot fold), TRI_PUSH=R,G,B,A sets 16 bytes of fragment push
 * constants, and TRI_WANT=0xAARRGGBB checks the three corner pixels against
 * it (each channel within 1). TRI_BLEND=1 blends the triangle over the
 * clear colour (0, 0, 0.25, 1) with premultiplied source-over (Hyprland's
 * blend): TRI_VCOL=0.25,0.5,0.75,0.5 TRI_WANT=0xff4080df. TRI_BLEND=dst
 * keeps the tile's colour (TRI_WANT=0xff000040).
 *
 * Depth: TRI_DEPTH=pass adds a D32_SFLOAT depth attachment, cleared to 1.0,
 * and a pipeline with depth test LESS and depth writes: the triangle (z 0)
 * passes and is drawn. TRI_DEPTH=fail clears it to 0.0: the triangle fails
 * and only the clear colour remains. TRI_DEPTH=load stores that 0.0 from a
 * render without draws and loads it in a second one that draws: the
 * triangle fails only if the depth went to memory and came back.
 * TRI_DEPTH=loadfirst loads depth that nothing stored (the fill, 0x55 or
 * TRI_DEPTH_FILL=N) and draws: the triangle must at least not hang.
 *
 * Job tests (each a reproduction of a hang or blank frame Hyprland had):
 *   TRI_DRAWS=N        the draw N times (long control streams)
 *   TRI_INSTANCES=N    N instances of it (the parameter buffer)
 *   TRI_CLEARATT=1     vkCmdClearAttachments inside the render (glClear)
 *                      to (0.25, 0.5, 0.75, 1), the colour expected
 *                      outside the triangle
 *   TRI_LOAD=1         then the target once more with load op LOAD and
 *                      nothing drawn (2: the triangle drawn again): the
 *                      result must not change. 3: load, clear to
 *                      (0.25, 0.5, 0.75, 1), load again: that colour
 *                      everywhere, or the loads read stale texture cache
 *   TRI_PRE=N          first a clear into each of N other images
 *                      (TRI_PRE_LINEAR=1: linear ones), as a swapchain
 *   TRI_PRESAME=N      first N clears into the target itself
 *   TRI_DEV2=1         first a clear on a second device (another DRM file
 *                      and GPU VM in the process), kept open
 *   TRI_PAD_MB=N       an N MiB buffer bound first (higher GPU addresses)
 *   TRI_EXIT_NOW=1     exit right after the submit, the render still queued
 *   TRI_UBO=1          a fragment uniform buffer, vec4[32] (element i =
 *                      (i / 32, 0.5, 1 - i / 32, 1)), for TRI_FS_SPV;
 *                      TRI_UBO_FILE=F loads its 512 bytes from F;
 *                      TRI_UBO2_FILE=F: draw once more with a second set
 *   TRI_RGBA=1         an R8G8B8A8 target (pixels then read back swapped)
 *   TRI_STRIP=1        the triangle as a strip
 *   TRI_FLIPY=1        a negative-height viewport (as Zink sets for GL)
 *   TRI_SCISSOR=1      a scissor over the left 5/8: the green corner shows
 *                      the clear colour
 *   TRI_REPEAT=N       submit the command buffer N more times, each waited
 *                      for, and print the submit-to-fence times (the cost
 *                      of one render, or of TRI_LOAD's two)
 *
 * Built by mesa/build-vk-test.sh; run in the device chroot:
 *
 *   PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 vk-tri [OUT.ppm]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <vulkan/vulkan.h>

#include "tri_vert.spv.h"
#include "tri_frag.spv.h"
#include "tri_tex_frag.spv.h"
#include "tri_discard_frag.spv.h"
#include "tri_coord_frag.spv.h"

static unsigned W = 64, H = 64;

#define CHECK(x)                                                              \
	do {                                                                  \
		VkResult r_ = (x);                                            \
		if (r_ != VK_SUCCESS) {                                       \
			fprintf(stderr, "%s: %d\n", #x, r_);                    \
			exit(1);                                              \
		}                                                             \
	} while (0)

static VkDevice dev;
static VkPhysicalDevice phys;

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;

	vkGetPhysicalDeviceMemoryProperties(phys, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	fprintf(stderr, "no memory type\n");
	exit(1);
}

static VkDeviceMemory alloc_bind(VkMemoryRequirements req, void **map)
{
	VkMemoryAllocateInfo ai = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = req.size,
		.memoryTypeIndex = memory_type(req.memoryTypeBits,
					       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
						       VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
	};
	VkDeviceMemory mem;

	CHECK(vkAllocateMemory(dev, &ai, NULL, &mem));
	CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, map));
	return mem;
}

static VkShaderModule module(const uint32_t *code, size_t size);

/* A shader module from a SPIR-V file */
static VkShaderModule module_file(const char *path)
{
	FILE *f = fopen(path, "rb");
	static uint32_t code[65536];
	size_t size;

	if (!f) {
		perror(path);
		exit(1);
	}
	size = fread(code, 1, sizeof(code), f);
	fclose(f);
	return module(code, size);
}

static VkShaderModule module(const uint32_t *code, size_t size)
{
	VkShaderModuleCreateInfo ci = {
		.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = size,
		.pCode = code,
	};
	VkShaderModule m;

	CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
	return m;
}

static unsigned pow2(unsigned v)
{
	unsigned p = 1;

	while (p < v)
		p <<= 1;
	return p;
}

/*
 * Twiddled index over the power-of-two padded size: x and y bits
 * interleaved (y first) while both have bits, then the longer side's
 */
static unsigned twiddle_wh(unsigned x, unsigned y, unsigned w, unsigned h)
{
	unsigned pw = pow2(w), ph = pow2(h), m = 0, bit = 0;

	for (unsigned i = 0; (1u << i) < pw || (1u << i) < ph; i++) {
		if ((1u << i) < ph)
			m |= ((y >> i) & 1) << bit++;
		if ((1u << i) < pw)
			m |= ((x >> i) & 1) << bit++;
	}
	return m;
}

static unsigned twiddle(unsigned x, unsigned y)
{
	return twiddle_wh(x, y, W, H);
}

static int linear_tiling;
static VkDeviceSize row_pitch;

static uint32_t pixel(const uint32_t *px, unsigned x, unsigned y)
{
	if (linear_tiling)
		return px[y * (row_pitch / 4) + x];
	return px[twiddle(x, y)];
}

int main(int argc, char **argv)
{
	float verts[] = {
		/* x, y, r, g, b, a */
		-0.5f, -0.5f, 1, 0, 0, 1,
		0.5f, -0.5f, 0, 1, 0, 1,
		0.0f, 0.5f, 0, 0, 1, 1,
	};
	float clear[4] = { 0.0f, 0.0f, 0.25f, 1.0f };
	/* TRI_RGBA=1: an R8G8B8A8 target (its pixels then read back swapped) */
	const VkFormat target_format =
		getenv("TRI_RGBA") ? VK_FORMAT_R8G8B8A8_UNORM : VK_FORMAT_B8G8R8A8_UNORM;
	const char *dev_ext[] = { VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME };
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
				  .apiVersion = VK_API_VERSION_1_2 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
				     .pApplicationInfo = &app };
	VkInstance inst;
	uint32_t n = 1;
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
					.queueCount = 1, .pQueuePriorities = &prio };
	VkPhysicalDeviceDynamicRenderingFeaturesKHR dr = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
		.dynamicRendering = VK_TRUE,
	};
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &dr,
				   .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
				   .enabledExtensionCount = 1, .ppEnabledExtensionNames = dev_ext };
	VkQueue queue;
	VkImage image;
	VkImageView view;
	/* TRI_DEPTH: the depth attachment */
	const char *depth_mode = getenv("TRI_DEPTH");
	VkImage dimage = VK_NULL_HANDLE;
	VkImageView dview = VK_NULL_HANDLE;
	uint32_t *dmap = NULL;
	VkDeviceSize dsize = 0;
	VkBuffer vb;
	VkMemoryRequirements req;
	VkDeviceMemory image_mem, vb_mem;
	void *image_map, *vb_map;
	VkPipelineLayout layout;
	VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
	VkDescriptorSet set = VK_NULL_HANDLE;
	VkDescriptorSet set2 = VK_NULL_HANDLE;	/* TRI_UBO2_FILE */
	const char *tex_mode = getenv("TRI_TEX");
	VkPipeline pipe;
	VkCommandPool pool;
	VkCommandBuffer cmd;
	VkFence fence;
	PFN_vkCmdBeginRenderingKHR begin_rendering;
	PFN_vkCmdEndRenderingKHR end_rendering;
	const char *env = getenv("TRI_CLEAR");

	if (env)
		sscanf(env, "%f,%f,%f,%f", &clear[0], &clear[1], &clear[2], &clear[3]);
	if (getenv("TRI_SIZE"))
		sscanf(getenv("TRI_SIZE"), "%ux%u", &W, &H);
	linear_tiling = getenv("TRI_LINEAR") != NULL;

	CHECK(vkCreateInstance(&ici, NULL, &inst));
	CHECK(vkEnumeratePhysicalDevices(inst, &n, &phys));
	CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	if (getenv("TRI_PAD_MB")) {
		VkBufferCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
					   .size = (VkDeviceSize)atoi(getenv("TRI_PAD_MB")) << 20,
					   .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT };
		VkMemoryRequirements req;
		VkBuffer pad;
		void *pad_map;

		CHECK(vkCreateBuffer(dev, &pci, NULL, &pad));
		vkGetBufferMemoryRequirements(dev, pad, &req);
		CHECK(vkBindBufferMemory(dev, pad, alloc_bind(req, &pad_map), 0));
	}
	begin_rendering = (PFN_vkCmdBeginRenderingKHR)vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR");
	end_rendering = (PFN_vkCmdEndRenderingKHR)vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR");
	if (getenv("TRI_DEV2")) {
		const VkDevice first = dev;
		VkImageCreateInfo ici = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
			.format = target_format, .extent = { W, H, 1 }, .mipLevels = 1,
			.arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
			.tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
		};
		VkImageViewCreateInfo vci = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
			.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = target_format,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
		};
		VkRenderingAttachmentInfoKHR att2 = {
			.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR,
			.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		};
		VkRenderingInfoKHR ri2 = {
			.sType = VK_STRUCTURE_TYPE_RENDERING_INFO_KHR, .renderArea = { { 0, 0 }, { W, H } },
			.layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att2,
		};
		VkCommandPoolCreateInfo pci2 = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
		VkCommandBufferAllocateInfo ai2 = {
			.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
			.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1,
		};
		VkCommandBufferBeginInfo bi2 = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		VkFenceCreateInfo fci2 = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
		VkSubmitInfo si2 = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1 };
		VkMemoryRequirements req2;
		VkCommandBuffer cmd2;
		VkCommandPool pool2;
		VkQueue queue2;
		VkFence fence2;
		void *map2;

		CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
		vkGetDeviceQueue(dev, 0, 0, &queue2);
		CHECK(vkCreateImage(dev, &ici, NULL, &vci.image));
		vkGetImageMemoryRequirements(dev, vci.image, &req2);
		CHECK(vkBindImageMemory(dev, vci.image, alloc_bind(req2, &map2), 0));
		CHECK(vkCreateImageView(dev, &vci, NULL, &att2.imageView));
		CHECK(vkCreateCommandPool(dev, &pci2, NULL, &pool2));
		ai2.commandPool = pool2;
		CHECK(vkAllocateCommandBuffers(dev, &ai2, &cmd2));
		CHECK(vkBeginCommandBuffer(cmd2, &bi2));
		((PFN_vkCmdBeginRenderingKHR)vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))(cmd2, &ri2);
		((PFN_vkCmdEndRenderingKHR)vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))(cmd2);
		CHECK(vkEndCommandBuffer(cmd2));
		si2.pCommandBuffers = &cmd2;
		CHECK(vkCreateFence(dev, &fci2, NULL, &fence2));
		CHECK(vkQueueSubmit(queue2, 1, &si2, fence2));
		CHECK(vkWaitForFences(dev, 1, &fence2, VK_TRUE, 2000000000ull));
		printf("second device: clear done\n");
		dev = first;
	}

	{
		VkImageCreateInfo ci = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
			.imageType = VK_IMAGE_TYPE_2D,
			.format = target_format,
			.extent = { W, H, 1 },
			.mipLevels = 1,
			.arrayLayers = 1,
			.samples = VK_SAMPLE_COUNT_1_BIT,
			.tiling = linear_tiling ? VK_IMAGE_TILING_LINEAR : VK_IMAGE_TILING_OPTIMAL,
			.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
		};

		CHECK(vkCreateImage(dev, &ci, NULL, &image));
		vkGetImageMemoryRequirements(dev, image, &req);
		image_mem = alloc_bind(req, &image_map);
		CHECK(vkBindImageMemory(dev, image, image_mem, 0));
		memset(image_map, 0x55, req.size);
		if (linear_tiling) {
			VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
			VkSubresourceLayout l;

			vkGetImageSubresourceLayout(dev, image, &sub, &l);
			row_pitch = l.rowPitch;
			printf("linear, row pitch %llu\n", (unsigned long long)row_pitch);
		}
	}
	{
		VkImageViewCreateInfo ci = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
			.image = image,
			.viewType = VK_IMAGE_VIEW_TYPE_2D,
			.format = target_format,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
		};

		CHECK(vkCreateImageView(dev, &ci, NULL, &view));
	}
	if (depth_mode) {
		VkImageCreateInfo ci = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
			.imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_D32_SFLOAT,
			.extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
			.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
			.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
		};
		VkImageViewCreateInfo vci = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
			.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_D32_SFLOAT,
			.subresourceRange = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1 },
		};
		void *map;

		CHECK(vkCreateImage(dev, &ci, NULL, &dimage));
		vkGetImageMemoryRequirements(dev, dimage, &req);
		CHECK(vkBindImageMemory(dev, dimage, alloc_bind(req, &map), 0));
		memset(map, getenv("TRI_DEPTH_FILL") ? atoi(getenv("TRI_DEPTH_FILL")) : 0x55, req.size);
		dmap = map;
		dsize = req.size;
		vci.image = dimage;
		CHECK(vkCreateImageView(dev, &vci, NULL, &dview));
	}
	{
		VkBufferCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
					  .size = sizeof(verts),
					  .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT };

		CHECK(vkCreateBuffer(dev, &ci, NULL, &vb));
		vkGetBufferMemoryRequirements(dev, vb, &req);
		vb_mem = alloc_bind(req, &vb_map);
		CHECK(vkBindBufferMemory(dev, vb, vb_mem, 0));
		if (getenv("TRI_VCOL")) {
			float v[4] = { 0, 0, 0, 1 };

			sscanf(getenv("TRI_VCOL"), "%f,%f,%f,%f", &v[0], &v[1], &v[2], &v[3]);
			for (unsigned i = 0; i < 3; i++)
				memcpy(&verts[6 * i + 2], v, sizeof(v));
		}
		memcpy(vb_map, verts, sizeof(verts));
	}
	if (tex_mode) {
		const int lin = !strcmp(tex_mode, "linear");
		unsigned tw = 4, th = 4;

		if (getenv("TRI_TEX_SIZE"))
			sscanf(getenv("TRI_TEX_SIZE"), "%ux%u", &tw, &th);
		VkImageCreateInfo ici2 = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
			.imageType = VK_IMAGE_TYPE_2D,
			.format = VK_FORMAT_R8G8B8A8_UNORM,
			.extent = { tw, th, 1 },
			.mipLevels = 1,
			.arrayLayers = 1,
			.samples = VK_SAMPLE_COUNT_1_BIT,
			.tiling = lin ? VK_IMAGE_TILING_LINEAR : VK_IMAGE_TILING_OPTIMAL,
			.usage = VK_IMAGE_USAGE_SAMPLED_BIT,
		};
		VkImage timg;
		VkImageView tview;
		VkSampler smp;
		void *tmap;
		VkDeviceSize pitch = 16;
		VkSamplerCreateInfo sci = {
			.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
			.magFilter = getenv("TRI_FILTER") ? VK_FILTER_LINEAR : VK_FILTER_NEAREST,
			.minFilter = getenv("TRI_FILTER") ? VK_FILTER_LINEAR : VK_FILTER_NEAREST,
			/* TRI_WRAP=repeat: repeat instead of clamping past the edges */
			.addressModeU = getenv("TRI_WRAP") ? VK_SAMPLER_ADDRESS_MODE_REPEAT
							  : VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			.addressModeV = getenv("TRI_WRAP") ? VK_SAMPLER_ADDRESS_MODE_REPEAT
							  : VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
			.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
		};
		VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1,
						   VK_SHADER_STAGE_FRAGMENT_BIT, NULL };
		VkDescriptorSetLayoutCreateInfo lci = {
			.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			.bindingCount = 1, .pBindings = &b };
		VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1 };
		VkDescriptorPoolCreateInfo pci2 = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
						    .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
		VkDescriptorPool pool2;
		VkDescriptorSetAllocateInfo sai = {
			.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
			.descriptorSetCount = 1 };
		VkDescriptorImageInfo dii;
		VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
					    .descriptorCount = 1,
					    .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
					    .pImageInfo = &dii };
		VkImageViewCreateInfo vci = {
			.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
			.viewType = VK_IMAGE_VIEW_TYPE_2D,
			.format = VK_FORMAT_R8G8B8A8_UNORM,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
		};

		CHECK(vkCreateImage(dev, &ici2, NULL, &timg));
		vkGetImageMemoryRequirements(dev, timg, &req);
		CHECK(vkBindImageMemory(dev, timg, alloc_bind(req, &tmap), 0));
		if (lin) {
			VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
			VkSubresourceLayout l;

			vkGetImageSubresourceLayout(dev, timg, &sub, &l);
			pitch = l.rowPitch;
		}
		for (unsigned y = 0; y < th; y++)
			for (unsigned x = 0; x < tw; x++) {
				uint32_t v = getenv("TRI_TEX_SIZE")
						     ? 0xff000080u | (x * 255 / (tw - 1)) << 16 |
							       (y * 255 / (th - 1)) << 8
						     : 0xff000080u | (x * 0x40) << 16 | (y * 0x40) << 8;

				if (lin)
					memcpy((uint8_t *)tmap + y * pitch + 4 * x, &v, 4);
				else
					((uint32_t *)tmap)[twiddle_wh(x, y, tw, th)] = v;
			}
		vci.image = timg;
		CHECK(vkCreateImageView(dev, &vci, NULL, &tview));
		CHECK(vkCreateSampler(dev, &sci, NULL, &smp));
		CHECK(vkCreateDescriptorSetLayout(dev, &lci, NULL, &set_layout));
		CHECK(vkCreateDescriptorPool(dev, &pci2, NULL, &pool2));
		sai.descriptorPool = pool2;
		sai.pSetLayouts = &set_layout;
		CHECK(vkAllocateDescriptorSets(dev, &sai, &set));
		dii = (VkDescriptorImageInfo){ smp, tview, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
		wr.dstSet = set;
		vkUpdateDescriptorSets(dev, 1, &wr, 0, NULL);
	}
	if (getenv("TRI_UBO") && !set_layout) {
		/*
		 * TRI_UBO=1: a fragment uniform buffer of vec4[32] at set 0
		 * binding 0, element i = (i / 32, 0.5, 1 - i / 32, 1), for
		 * TRI_FS_SPV shaders reading far into it
		 */
		VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
					   .size = 512, .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT };
		VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1,
						   VK_SHADER_STAGE_FRAGMENT_BIT, NULL };
		VkDescriptorSetLayoutCreateInfo lci = {
			.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			.bindingCount = 1, .pBindings = &b };
		VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2 };
		VkDescriptorPoolCreateInfo pci2 = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
						    .maxSets = 2, .poolSizeCount = 1, .pPoolSizes = &ps };
		VkDescriptorSetAllocateInfo sai = {
			.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
			.descriptorSetCount = 1 };
		VkDescriptorBufferInfo dbi;
		VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
					    .descriptorCount = 1,
					    .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
					    .pBufferInfo = &dbi };
		VkMemoryRequirements req;
		VkDescriptorPool pool2;
		VkBuffer ubuf;
		float *u;

		CHECK(vkCreateBuffer(dev, &bci, NULL, &ubuf));
		vkGetBufferMemoryRequirements(dev, ubuf, &req);
		CHECK(vkBindBufferMemory(dev, ubuf, alloc_bind(req, (void **)&u), 0));
		for (unsigned i = 0; i < 32; i++) {
			u[4 * i] = i / 32.0f;
			u[4 * i + 1] = 0.5f;
			u[4 * i + 2] = 1.0f - i / 32.0f;
			u[4 * i + 3] = 1.0f;
		}
		/* TRI_UBO_FILE: the buffer's 512 bytes from a file (a G9P_DUMP_FULL "fs buffer") */
		if (getenv("TRI_UBO_FILE")) {
			FILE *f = fopen(getenv("TRI_UBO_FILE"), "rb");

			if (!f || fread(u, 1, 512, f) != 512) {
				perror(getenv("TRI_UBO_FILE"));
				return 1;
			}
			fclose(f);
		}
		CHECK(vkCreateDescriptorSetLayout(dev, &lci, NULL, &set_layout));
		CHECK(vkCreateDescriptorPool(dev, &pci2, NULL, &pool2));
		sai.descriptorPool = pool2;
		sai.pSetLayouts = &set_layout;
		CHECK(vkAllocateDescriptorSets(dev, &sai, &set));
		dbi = (VkDescriptorBufferInfo){ ubuf, 0, 512 };
		wr.dstSet = set;
		vkUpdateDescriptorSets(dev, 1, &wr, 0, NULL);
		/*
		 * TRI_UBO2_FILE: a second buffer and set; the triangle is drawn
		 * with the first set, then again with the second (uniforms of
		 * consecutive draws kept apart?)
		 */
		if (getenv("TRI_UBO2_FILE")) {
			VkBuffer ubuf2;
			FILE *f = fopen(getenv("TRI_UBO2_FILE"), "rb");

			CHECK(vkCreateBuffer(dev, &bci, NULL, &ubuf2));
			CHECK(vkBindBufferMemory(dev, ubuf2, alloc_bind(req, (void **)&u), 0));
			if (!f || fread(u, 1, 512, f) != 512) {
				perror(getenv("TRI_UBO2_FILE"));
				return 1;
			}
			fclose(f);
			CHECK(vkAllocateDescriptorSets(dev, &sai, &set2));
			dbi = (VkDescriptorBufferInfo){ ubuf2, 0, 512 };
			wr.dstSet = set2;
			vkUpdateDescriptorSets(dev, 1, &wr, 0, NULL);
		}
	}
	{
		/* 16 bytes of fragment push constants (TRI_PUSH=R,G,B,A sets them) */
		VkPushConstantRange pcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, 16 };
		VkPipelineLayoutCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
						  .setLayoutCount = set_layout ? 1 : 0,
						  .pSetLayouts = &set_layout,
						  .pushConstantRangeCount = 1,
						  .pPushConstantRanges = &pcr };

		CHECK(vkCreatePipelineLayout(dev, &ci, NULL, &layout));
	}
	{
		VkPipelineShaderStageCreateInfo stages[2] = {
			{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			  .stage = VK_SHADER_STAGE_VERTEX_BIT,
			  .module = getenv("TRI_VS_SPV") ? module_file(getenv("TRI_VS_SPV"))
							   : module(tri_vert_spv, sizeof(tri_vert_spv)),
			  .pName = "main" },
			{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			  .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
			  /* TRI_DISCARD=1: discard where red > 0.5 */
			  .module = getenv("TRI_FS_SPV") ? module_file(getenv("TRI_FS_SPV"))
				    : tex_mode ? module(tri_tex_frag_spv, sizeof(tri_tex_frag_spv))
				    : getenv("TRI_COORD")
					     ? module(tri_coord_frag_spv, sizeof(tri_coord_frag_spv))
				    : getenv("TRI_DISCARD")
					     ? module(tri_discard_frag_spv, sizeof(tri_discard_frag_spv))
					     : module(tri_frag_spv, sizeof(tri_frag_spv)),
			  .pName = "main" },
		};
		VkVertexInputBindingDescription bind = { 0, 6 * sizeof(float), VK_VERTEX_INPUT_RATE_VERTEX };
		VkVertexInputAttributeDescription attrs[2] = {
			{ 0, 0, VK_FORMAT_R32G32_SFLOAT, 0 },
			{ 1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 2 * sizeof(float) },
		};
		VkPipelineVertexInputStateCreateInfo vi = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			.vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &bind,
			.vertexAttributeDescriptionCount = 2, .pVertexAttributeDescriptions = attrs,
		};
		VkPipelineInputAssemblyStateCreateInfo ia = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			/* TRI_STRIP=1: the same triangle as a strip */
			.topology = getenv("TRI_STRIP") ? VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
						     : VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
		};
		/* TRI_FLIPY=1: a negative-height viewport (Y up, as Zink sets for GL) */
		VkViewport vp = getenv("TRI_FLIPY") ? (VkViewport){ 0, (float)H, (float)W, -(float)H, 0, 1 }
						    : (VkViewport){ 0, 0, (float)W, (float)H, 0, 1 };
		/* TRI_SCISSOR=1: the left 5/8 only (the green corner is cut off) */
		VkRect2D sc = { { 0, 0 }, { getenv("TRI_SCISSOR") ? W * 5 / 8 : W, H } };
		VkPipelineViewportStateCreateInfo vps = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc,
		};
		VkPipelineRasterizationStateCreateInfo rs = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
			.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1,
		};
		VkPipelineMultisampleStateCreateInfo ms = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
		};
		VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
		if (getenv("TRI_BLEND"))
			cba = (VkPipelineColorBlendAttachmentState){
				.blendEnable = VK_TRUE,
				.srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
				.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
				.colorBlendOp = VK_BLEND_OP_ADD,
				.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
				.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
				.alphaBlendOp = VK_BLEND_OP_ADD,
				.colorWriteMask = 0xf,
			};
		/* TRI_BLEND=dst: the tile's colour unchanged (the clear colour) */
		if (getenv("TRI_BLEND") && !strcmp(getenv("TRI_BLEND"), "dst")) {
			cba.srcColorBlendFactor = cba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
			cba.dstColorBlendFactor = cba.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
		}
		VkPipelineColorBlendStateCreateInfo cb = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			.attachmentCount = 1, .pAttachments = &cba,
		};
		VkFormat fmt = target_format;
		VkPipelineRenderingCreateInfoKHR rci = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR,
			.colorAttachmentCount = 1, .pColorAttachmentFormats = &fmt,
			.depthAttachmentFormat = depth_mode ? VK_FORMAT_D32_SFLOAT : VK_FORMAT_UNDEFINED,
		};
		VkPipelineDepthStencilStateCreateInfo dss = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			.depthTestEnable = VK_TRUE, .depthWriteEnable = VK_TRUE,
			.depthCompareOp = VK_COMPARE_OP_LESS,
		};
		VkGraphicsPipelineCreateInfo ci = {
			.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rci,
			.stageCount = 2, .pStages = stages, .pVertexInputState = &vi,
			.pInputAssemblyState = &ia, .pViewportState = &vps,
			.pRasterizationState = &rs, .pMultisampleState = &ms,
			.pDepthStencilState = depth_mode ? &dss : NULL,
			.pColorBlendState = &cb, .layout = layout,
		};

		CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &pipe));
	}
	{
		VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
		VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
						   .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
						   .commandBufferCount = 1 };
		VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		VkRenderingAttachmentInfoKHR att = {
			.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR,
			.imageView = view,
			.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		};
		VkRenderingAttachmentInfoKHR datt = {
			.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR,
			.imageView = dview,
			.imageLayout = VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
			.loadOp = depth_mode && !strcmp(depth_mode, "loadfirst")
					  ? VK_ATTACHMENT_LOAD_OP_LOAD : VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = VK_ATTACHMENT_STORE_OP_STORE,
			.clearValue.depthStencil.depth =
				depth_mode && strcmp(depth_mode, "pass") ? 0.0f : 1.0f,
		};
		VkRenderingInfoKHR ri = {
			.sType = VK_STRUCTURE_TYPE_RENDERING_INFO_KHR,
			.renderArea = { { 0, 0 }, { W, H } },
			.layerCount = 1,
			.colorAttachmentCount = 1,
			.pColorAttachments = &att,
			.pDepthAttachment = depth_mode ? &datt : NULL,
		};
		VkDeviceSize zero = 0;

		memcpy(att.clearValue.color.float32, clear, sizeof(clear));
		CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
		ai.commandPool = pool;
		CHECK(vkAllocateCommandBuffers(dev, &ai, &cmd));
		CHECK(vkBeginCommandBuffer(cmd, &bi));
		for (int p = 0; p < (getenv("TRI_PRE") ? atoi(getenv("TRI_PRE")) : 0); p++) {
			VkImageCreateInfo ici = {
				.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
				.imageType = VK_IMAGE_TYPE_2D, .format = target_format,
				.extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
				.samples = VK_SAMPLE_COUNT_1_BIT,
				.tiling = getenv("TRI_PRE_LINEAR") ? VK_IMAGE_TILING_LINEAR
								   : VK_IMAGE_TILING_OPTIMAL,
				.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
			};
			VkImageViewCreateInfo vci = {
				.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
				.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = target_format,
				.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
			};
			VkRenderingAttachmentInfoKHR pre_att = att;
			VkRenderingInfoKHR pre_ri = ri;
			VkMemoryRequirements preq;
			void *pre_map;

			CHECK(vkCreateImage(dev, &ici, NULL, &vci.image));
			vkGetImageMemoryRequirements(dev, vci.image, &preq);
			CHECK(vkBindImageMemory(dev, vci.image, alloc_bind(preq, &pre_map), 0));
			CHECK(vkCreateImageView(dev, &vci, NULL, &pre_att.imageView));
			pre_ri.pColorAttachments = &pre_att;
			begin_rendering(cmd, &pre_ri);
			end_rendering(cmd);
		}
		for (int p = 0; p < (getenv("TRI_PRESAME") ? atoi(getenv("TRI_PRESAME")) : 0); p++) {
			begin_rendering(cmd, &ri);
			end_rendering(cmd);
		}
		begin_rendering(cmd, &ri);
		if (getenv("TRI_CLEARATT")) {
			VkClearAttachment ca = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT };
			VkClearRect cr = { .rect = ri.renderArea, .layerCount = 1 };

			const float c2[4] = { 0.25f, 0.5f, 0.75f, 1.0f };

			memcpy(ca.clearValue.color.float32, c2, sizeof(c2));
			vkCmdClearAttachments(cmd, 1, &ca, 1, &cr);
			memcpy(clear, c2, sizeof(c2));
		}
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
		if (getenv("TRI_PUSH")) {
			float pc[4] = { 0, 0, 0, 1 };

			sscanf(getenv("TRI_PUSH"), "%f,%f,%f,%f", &pc[0], &pc[1], &pc[2], &pc[3]);
			vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(pc), pc);
		}
		vkCmdBindVertexBuffers(cmd, 0, 1, &vb, &zero);
		if (set)
			vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set,
						0, NULL);
		if (set2) {
			vkCmdDraw(cmd, 3, 1, 0, 0);
			vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1,
						&set2, 0, NULL);
		}
		/* TRI_NODRAW=1: only the clear; TRI_DEPTH=load draws in a second render */
		if (!getenv("TRI_NODRAW") && !(depth_mode && !strcmp(depth_mode, "load")))
			for (int i = 0; i < (getenv("TRI_DRAWS") ? atoi(getenv("TRI_DRAWS")) : 1); i++)
				vkCmdDraw(cmd, 3,
					  getenv("TRI_INSTANCES") ? atoi(getenv("TRI_INSTANCES")) : 1,
					  0, 0);
		end_rendering(cmd);
		if (depth_mode && !strcmp(depth_mode, "load")) {
			datt.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
			att.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
			begin_rendering(cmd, &ri);
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
			vkCmdBindVertexBuffers(cmd, 0, 1, &vb, &zero);
			vkCmdDraw(cmd, 3, 1, 0, 0);
			end_rendering(cmd);
		}
		if (getenv("TRI_LOAD")) {
			att.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
			begin_rendering(cmd, &ri);
			if (atoi(getenv("TRI_LOAD")) == 2) {
				vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
				vkCmdBindVertexBuffers(cmd, 0, 1, &vb, &zero);
				vkCmdDraw(cmd, 3, 1, 0, 0);
			}
			end_rendering(cmd);
			if (atoi(getenv("TRI_LOAD")) == 3) {
				const float c3[4] = { 0.25f, 0.5f, 0.75f, 1.0f };

				att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
				memcpy(att.clearValue.color.float32, c3, sizeof(c3));
				begin_rendering(cmd, &ri);
				end_rendering(cmd);
				att.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
				begin_rendering(cmd, &ri);
				end_rendering(cmd);
				memcpy(clear, c3, sizeof(c3));
			}
		}
		CHECK(vkEndCommandBuffer(cmd));
	}
	{
		VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
		VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
				    .commandBufferCount = 1, .pCommandBuffers = &cmd };

		CHECK(vkCreateFence(dev, &fci, NULL, &fence));
		CHECK(vkQueueSubmit(queue, 1, &si, fence));
		/* TRI_EXIT_NOW=1: exit with the render still on the GPU (a client killed mid-frame) */
		if (getenv("TRI_EXIT_NOW"))
			_exit(0);
		CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 2000000000ull));
		if (getenv("TRI_REPEAT")) {
			const int n = atoi(getenv("TRI_REPEAT"));
			double sum = 0, lo = 1e9, hi = 0;

			for (int i = 0; i < n; i++) {
				struct timespec t0, t1;

				CHECK(vkResetFences(dev, 1, &fence));
				clock_gettime(CLOCK_MONOTONIC, &t0);
				CHECK(vkQueueSubmit(queue, 1, &si, fence));
				CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 2000000000ull));
				clock_gettime(CLOCK_MONOTONIC, &t1);
				const double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;

				sum += ms;
				lo = ms < lo ? ms : lo;
				hi = ms > hi ? ms : hi;
			}
			if (n > 0)
				printf("repeat %d: submit to fence %.2f ms average, %.2f min, %.2f max\n", n,
				       sum / n, lo, hi);
		}
	}

	{
		const uint32_t *px = image_map;
		const uint32_t want_clear = (uint32_t)(clear[3] * 255 + 0.5f) << 24 |
					    (uint32_t)(clear[0] * 255 + 0.5f) << 16 |
					    (uint32_t)(clear[1] * 255 + 0.5f) << 8 |
					    (uint32_t)(clear[2] * 255 + 0.5f);
		/* screen corners of the triangle (Vulkan: y down), slightly inside */
		unsigned at[3][2] = { { W * 19 / 64, H * 18 / 64 }, { W * 45 / 64, H * 18 / 64 },
					    { W / 2, H * 45 / 64 } };

		/* TRI_FLIPY: the image is mirrored vertically */
		if (getenv("TRI_FLIPY"))
			for (unsigned i = 0; i < 3; i++)
				at[i][1] = H - 1 - at[i][1];
		static const char *names[3] = { "red", "green", "blue" };
		/* TRI_DEPTH=fail: the depth test rejects the triangle */
		if (dmap) {
			/* what the depth store wrote: words other than the 0x55 fill */
			unsigned changed = 0, first = ~0u;

			for (VkDeviceSize i = 0; i < dsize / 4; i++)
				if (dmap[i] != 0x55555555u) {
					changed++;
					if (first == ~0u)
						first = i;
				}
			printf("depth memory: %u of %llu words written", changed,
			       (unsigned long long)(dsize / 4));
			if (changed)
				printf(", first at word %u: %#x", first, dmap[first]);
			printf("\n");
			/* TRI_DEPTH_DUMP=1: the written ranges and their values */
			if (getenv("TRI_DEPTH_DUMP"))
				for (VkDeviceSize i = 0, n = 0; i < dsize / 4 && n < 24; i++) {
					VkDeviceSize j = i;

					if (dmap[i] == 0x55555555u)
						continue;
					while (j + 1 < dsize / 4 && dmap[j + 1] != 0x55555555u)
						j++;
					printf("  words %llu-%llu: %#x .. %#x\n", (unsigned long long)i,
					       (unsigned long long)j, dmap[i], dmap[j]);
					i = j;
					n++;
				}
		}
		if (depth_mode && !strcmp(depth_mode, "loadfirst")) {
			printf("PASS (completed; the loaded depth is undefined)\n");
			return 0;
		}
		const int nodraw = getenv("TRI_NODRAW") != NULL ||
				   (depth_mode && strcmp(depth_mode, "pass"));
		unsigned n_clear = 0, n_other = 0, ok = 1;

		for (unsigned y = 0; y < H; y++)
			for (unsigned x = 0; x < W; x++) {
				if (pixel(px, x, y) == want_clear)
					n_clear++;
				else
					n_other++;
			}
		printf("clear %#010x: %u pixels, other: %u\n", want_clear, n_clear, n_other);
		for (unsigned i = 0; i < 3 && !nodraw; i++) {
			uint32_t p = pixel(px, at[i][0], at[i][1]);
			unsigned c[3] = { p >> 16 & 0xff, p >> 8 & 0xff, p & 0xff };

			printf("near the %s corner (%u,%u): %#010x\n", names[i], at[i][0], at[i][1], p);
			/*
			 * TRI_COORD=1: red (x + 0.5) / 64, green (y + 0.5) / 64 (gl_FragCoord,
			 * not perspective-correct) and blue the vertex colour's (perspective)
			 */
			if (getenv("TRI_COORD")) {
				unsigned wr = (unsigned)((at[i][0] + 0.5f) / 64 * 255 + 0.5f);
				unsigned wg = (unsigned)((at[i][1] + 0.5f) / 64 * 255 + 0.5f);

				printf("   want red %02x green %02x\n", wr, wg);
				ok &= abs((int)c[0] - (int)wr) <= 1 && abs((int)c[1] - (int)wg) <= 1 &&
				      (c[2] > 0xa0) == (i == 2);
				continue;
			}
			if (tex_mode) {
				/*
				 * texel at (r, g) of the vertex colour: (3, 0), (0, 3), (0, 0) as
				 * BGRA8 0xAARRGGBB of RGBA texel (0x80, 0x40 y, 0x40 x)
				 */
				static const uint32_t want[3] = { 0xff8000c0, 0xff80c000, 0xff800000 };

				/* TRI_TEX_SIZE: x (blue) high at red, y (green) at green, neither at blue */
				if (getenv("TRI_TEX_SIZE"))
					ok &= abs((int)c[0] - 0x80) <= 2 && (c[2] > 0xa0) == (i == 0) &&
					      (c[1] > 0xa0) == (i == 1);
				else
					ok &= getenv("TRI_FILTER") || p == want[i];
				continue;
			}
			if (getenv("TRI_WANT")) {
				const uint32_t want = strtoul(getenv("TRI_WANT"), NULL, 16);

				for (unsigned k = 0; k < 32; k += 8)
					ok &= abs((int)(p >> k & 0xff) - (int)(want >> k & 0xff)) <= 1;
				continue;
			}
			/* TRI_DISCARD: the red corner is discarded (the clear colour) */
			if ((getenv("TRI_DISCARD") && i == 0) || (getenv("TRI_SCISSOR") && i == 1)) {
				ok &= p == want_clear;
				continue;
			}
			ok &= c[i] > 0xa0 && c[(i + 1) % 3] < 0x60 && c[(i + 2) % 3] < 0x60;
		}
		/* the triangle covers 1/8 of the target, 3/32 after the discard */
		/* TRI_BLEND=dst: the triangle keeps the clear colour */
		if (nodraw || (getenv("TRI_BLEND") && !strcmp(getenv("TRI_BLEND"), "dst")))
			ok &= n_other == 0;
		else if (getenv("TRI_DISCARD") || getenv("TRI_SCISSOR"))
			ok &= n_other > W * H / 16 && n_other < W * H / 8;
		else
			ok &= n_other > W * H / 10 && n_other < W * H / 6;
		if (argc > 1) {
			FILE *f = fopen(argv[1], "wb");

			fprintf(f, "P6 %d %d 255\n", W, H);
			for (unsigned y = 0; y < H; y++)
				for (unsigned x = 0; x < W; x++) {
					uint32_t p = pixel(px, x, y);
					unsigned char rgb[3] = { p >> 16, p >> 8, p };

					fwrite(rgb, 3, 1, f);
				}
			fclose(f);
		}
		if (getenv("TRI_FB")) {
			FILE *fb = fopen(getenv("TRI_FB"), "wb");
			uint32_t *row = malloc(4 * W);

			for (unsigned y = 0; fb && row && y < H; y++) {
				for (unsigned x = 0; x < W; x++)
					row[x] = pixel(px, x, y);
				fwrite(row, 4, W, fb);
			}
			if (fb)
				fclose(fb);
			free(row);
		}
		printf("%s\n", ok ? "PASS" : "FAIL");
		return ok ? 0 : 1;
	}
}
