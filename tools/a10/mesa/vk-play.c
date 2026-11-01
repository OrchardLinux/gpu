// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Shader player: runs a compute shader (SPIR-V file) every frame and shows
 * its output on /dev/fb0 (1536x2048), scaled up, with the text console in
 * graphics mode. The shader gets push constants {float time; uint width;
 * uint height;}, writes one XRGB8888 pixel per invocation into buffer
 * (set 0, binding 0) at y * width + x, and runs in workgroups of 64 x 1
 * over width/64 x height. Stops after SECONDS or when /run/fx.stop exists.
 *
 *   PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 vk-play SHADER.spv [SECONDS [WIDTH HEIGHT]]
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


#define FB_W 1536u
#define FB_H 2048u
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
	float time;
	uint32_t width, height;
};

static uint32_t *read_spirv(const char *path, size_t *size)
{
	FILE *f = fopen(path, "rb");
	uint32_t *code;

	if (!f) {
		perror(path);
		exit(1);
	}
	fseek(f, 0, SEEK_END);
	*size = ftell(f);
	rewind(f);
	code = malloc(*size);
	if (!code || fread(code, 1, *size, f) != *size)
		exit(1);
	fclose(f);
	return code;
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	double seconds = argc > 2 ? atof(argv[2]) : 10, t0;
	uint32_t W = argc > 4 ? strtoul(argv[3], NULL, 0) : 384;
	uint32_t H = argc > 4 ? strtoul(argv[4], NULL, 0) : 512;
	uint32_t sx = FB_W / W, sy = FB_H / H;
	size_t spv_size;
	uint32_t *spv;

	if (argc < 2 || W % 64 || !sx || !sy) {
		fprintf(stderr, "usage: vk-play SHADER.spv [SECONDS [WIDTH HEIGHT]] (WIDTH a multiple of 64)\n");
		return 2;
	}
	spv = read_spirv(argv[1], &spv_size);
	VkInstance instance;
	VkPhysicalDevice pdev;
	VkDevice dev;
	VkQueue queue;
	uint32_t count = 1, mem_type = UINT32_MAX, i, frames = 0;
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
		.codeSize = spv_size, .pCode = spv }, NULL, &module));
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

	{
		int fd = open("/dev/fb0", O_RDWR);

		tty = open("/dev/tty0", O_RDWR);
		if (tty >= 0)
			ioctl(tty, KDSETMODE, KD_GRAPHICS);
		fb = fd < 0 ? NULL : mmap(NULL, FB_STRIDE * FB_H, PROT_READ | PROT_WRITE,
					  MAP_SHARED, fd, 0);
		if (fb == MAP_FAILED)
			fb = NULL;
	}

	t0 = now();
	do {
		struct params p = { now() - t0, W, H };
		uint32_t x, y, k;

		CHECK(vkResetCommandBuffer(cmd, 0));
		CHECK(vkBeginCommandBuffer(cmd, &(VkCommandBufferBeginInfo){
			.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }));
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set,
					0, NULL);
		vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(p), &p);
		vkCmdDispatch(cmd, W / 64, H, 1);
		CHECK(vkEndCommandBuffer(cmd));
		CHECK(vkResetFences(dev, 1, &fence));
		CHECK(vkQueueSubmit(queue, 1, &(VkSubmitInfo){
			.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
			.pCommandBuffers = &cmd }, fence));
		CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 10000000000ull));

		if (fb) {
			for (y = 0; y < H; y++) {
				uint32_t *d0 = (uint32_t *)(fb + sy * y * FB_STRIDE);

				for (x = 0; x < W; x++)
					for (k = 0; k < sx; k++)
						d0[sx * x + k] = map[y * W + x];
				for (k = 1; k < sy; k++)
					memcpy(fb + (sy * y + k) * FB_STRIDE, d0, 4 * W * sx);
			}
		}
		frames++;
	} while (now() - t0 < seconds && access("/run/fx.stop", F_OK));

	if (tty >= 0)
		ioctl(tty, KDSETMODE, KD_TEXT);
	printf("%u frames in %.1f s: %.1f fps at %ux%u\n", frames, now() - t0,
	       frames / (now() - t0), W, H);
	return 0;
}
