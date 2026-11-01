// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Vulkan effect test: vk-fx.comp renders an animated Julia set (768x1024)
 * through the Mesa fork's G9P backend. The first frame is checked against a
 * CPU reference with the same float operations; with SECONDS it then
 * animates on /dev/fb0 (2x scaled, text console in graphics mode).
 *
 *   PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 vk-fx [SECONDS [ROWS]]
 *
 * ROWS renders (and checks) only the first rows, for debugging.
 */
#include <fcntl.h>
#include <linux/kd.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <vulkan/vulkan.h>

#include "vk-fx.spv.h"

#define W 768u
#define H 1024u
#define FB_STRIDE 6144u

#define CHECK(x)                                                         \
	do {                                                             \
		VkResult r_ = (x);                                       \
		if (r_ != VK_SUCCESS) {                                  \
			fprintf(stderr, "%s: %d\n", #x, r_);             \
			exit(1);                                         \
		}                                                        \
	} while (0)

struct params {
	float cx, cy, zoom, shift;
};

/* The shader's computation on the CPU, same operations and order */
static uint32_t reference(const struct params *p, uint32_t x, uint32_t y)
{
	float zx = ((float)x - 384.0f) * p->zoom, zy = ((float)y - 512.0f) * p->zoom;
	uint32_t i = 0, col = 0;

	for (; i < 128; i++) {
		float xx = zx * zx, yy = zy * zy;

		if (xx + yy > 16.0f)
			break;
		zy = 2.0f * zx * zy + p->cy;
		zx = xx - yy + p->cx;
	}
	if (i < 128) {
		uint32_t k = (i * 7u + (uint32_t)(p->shift * 255.0f)) & 255u;
		float g = (float)i * 4.0f;
		uint32_t glow = (uint32_t)(g < 255.0f ? g : 255.0f);
		uint32_t b = 255u - k > glow ? 255u - k : glow;

		col = k << 16 | ((k * 3u) & 255u) << 8 | b;
	}
	return 0xff000000u | col;
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	double seconds = argc > 1 ? atof(argv[1]) : 0, t0, t;
	uint32_t rows = argc > 2 ? strtoul(argv[2], NULL, 0) : H;
	VkInstance instance;
	VkPhysicalDevice pdev;
	VkDevice dev;
	VkQueue queue;
	uint32_t count = 1, mem_type = UINT32_MAX, bad = 0, i, frames = 0;
	VkDeviceSize size = 4 * W * H;

	CHECK(vkCreateInstance(&(VkInstanceCreateInfo){
		.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &(VkApplicationInfo){
			.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
			.apiVersion = VK_API_VERSION_1_1 },
	}, NULL, &instance));
	CHECK(vkEnumeratePhysicalDevices(instance, &count, &pdev));
	CHECK(vkCreateDevice(pdev, &(VkDeviceCreateInfo){
		.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &(VkDeviceQueueCreateInfo){
			.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
			.queueCount = 1, .pQueuePriorities = &(float){ 1.0f } },
	}, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkBuffer buf;
	VkDeviceMemory mem;
	VkMemoryRequirements req;
	VkPhysicalDeviceMemoryProperties props;
	uint32_t *map;

	CHECK(vkCreateBuffer(dev, &(VkBufferCreateInfo){
		.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
		.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT }, NULL, &buf));
	vkGetBufferMemoryRequirements(dev, buf, &req);
	vkGetPhysicalDeviceMemoryProperties(pdev, &props);
	for (i = 0; i < props.memoryTypeCount; i++)
		if ((req.memoryTypeBits & (1u << i)) &&
		    (props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
			mem_type = i;
			break;
		}
	CHECK(vkAllocateMemory(dev, &(VkMemoryAllocateInfo){
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = req.size, .memoryTypeIndex = mem_type }, NULL, &mem));
	CHECK(vkBindBufferMemory(dev, buf, mem, 0));
	CHECK(vkMapMemory(dev, mem, 0, size, 0, (void **)&map));

	VkDescriptorSetLayout dsl;
	VkPipelineLayout layout;
	VkShaderModule module;
	VkPipeline pipeline;
	VkDescriptorPool pool;
	VkDescriptorSet set;

	CHECK(vkCreateDescriptorSetLayout(dev, &(VkDescriptorSetLayoutCreateInfo){
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1,
		.pBindings = &(VkDescriptorSetLayoutBinding){
			.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
			.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
	}, NULL, &dsl));
	CHECK(vkCreatePipelineLayout(dev, &(VkPipelineLayoutCreateInfo){
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &dsl,
		.pushConstantRangeCount = 1,
		.pPushConstantRanges = &(VkPushConstantRange){
			VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(struct params) } }, NULL, &layout));
	CHECK(vkCreateShaderModule(dev, &(VkShaderModuleCreateInfo){
		.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = sizeof(vk_fx_spv), .pCode = vk_fx_spv }, NULL, &module));
	CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &(VkComputePipelineCreateInfo){
		.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			   .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = module,
			   .pName = "main" },
		.layout = layout }, NULL, &pipeline));
	CHECK(vkCreateDescriptorPool(dev, &(VkDescriptorPoolCreateInfo){
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
		.poolSizeCount = 1,
		.pPoolSizes = &(VkDescriptorPoolSize){ VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 },
	}, NULL, &pool));
	CHECK(vkAllocateDescriptorSets(dev, &(VkDescriptorSetAllocateInfo){
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &dsl }, &set));
	vkUpdateDescriptorSets(dev, 1, &(VkWriteDescriptorSet){
		.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set,
		.dstBinding = 0, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.pBufferInfo = &(VkDescriptorBufferInfo){ buf, 0, VK_WHOLE_SIZE } }, 0, NULL);

	VkCommandPool cpool;
	VkCommandBuffer cmd;
	VkFence fence;
	uint8_t *fb = NULL;
	int tty = -1;

	CHECK(vkCreateCommandPool(dev, &(VkCommandPoolCreateInfo){
		.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT }, NULL, &cpool));
	CHECK(vkAllocateCommandBuffers(dev, &(VkCommandBufferAllocateInfo){
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 }, &cmd));
	CHECK(vkCreateFence(dev, &(VkFenceCreateInfo){
		.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }, NULL, &fence));

	if (seconds > 0) {
		int fd = open("/dev/fb0", O_RDWR);

		tty = open("/dev/tty0", O_RDWR);
		if (tty >= 0)
			ioctl(tty, KDSETMODE, KD_GRAPHICS);
		fb = fd < 0 ? NULL : mmap(NULL, FB_STRIDE * 2 * H, PROT_READ | PROT_WRITE,
					  MAP_SHARED, fd, 0);
		if (fb == MAP_FAILED)
			fb = NULL;
	}

	t0 = now();
	do {
		struct params p;
		uint32_t x, y;

		t = now() - t0;
		p.cx = 0.7885f * cosf(0.35f * t);
		p.cy = 0.7885f * sinf(0.35f * t);
		p.zoom = (3.2f / H) * (0.8f + 0.2f * cosf(0.5f * t));
		p.shift = 0.05f * t;

		CHECK(vkResetCommandBuffer(cmd, 0));
		CHECK(vkBeginCommandBuffer(cmd, &(VkCommandBufferBeginInfo){
			.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }));
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set,
					0, NULL);
		vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(p), &p);
		vkCmdDispatch(cmd, W / 64, rows, 1);
		CHECK(vkEndCommandBuffer(cmd));
		CHECK(vkResetFences(dev, 1, &fence));
		CHECK(vkQueueSubmit(queue, 1, &(VkSubmitInfo){
			.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
			.pCommandBuffers = &cmd }, fence));
		CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull));

		if (!frames) {
			for (y = 0; y < rows; y++)
				for (x = 0; x < W; x++)
					if (map[y * W + x] != reference(&p, x, y) && !bad++)
						printf("first mismatch at %u,%u: %#x, expected %#x\n",
						       x, y, map[y * W + x], reference(&p, x, y));
			/*
			 * Pixels next to the set's boundary are chaotic: one
			 * rounding difference changes their iteration count
			 */
			printf("frame 0: %u of %u pixels differ from the CPU reference: %s\n",
			       bad, W * rows, bad > W * rows / 10000 ? "FAIL" : "PASS");
			if (bad <= W * rows / 10000)
				bad = 0;
		}
		if (fb) {
			for (y = 0; y < H; y++) {
				uint32_t *d0 = (uint32_t *)(fb + 2 * y * FB_STRIDE);

				for (x = 0; x < W; x++)
					d0[2 * x] = d0[2 * x + 1] = map[y * W + x];
				memcpy(fb + (2 * y + 1) * FB_STRIDE, d0, 8 * W);
			}
		}
		frames++;
	} while (now() - t0 < seconds && access("/run/fx.stop", F_OK));

	if (tty >= 0)
		ioctl(tty, KDSETMODE, KD_TEXT);
	if (seconds > 0)
		printf("%u frames in %.1f s: %.1f fps\n", frames, now() - t0,
		       frames / (now() - t0));
	return !!bad;
}
