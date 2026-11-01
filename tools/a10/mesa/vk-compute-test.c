// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Vulkan compute tests: one storage buffer, GROUPS workgroups of 64
 * invocations running shaders/NAME.comp, each checked against a CPU
 * reference through host-visible memory. Built by mesa/build-vk-test.sh;
 * run in the device chroot:
 *
 *   PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 vk-compute-test [NAME [GROUPS]]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

#include "basic.spv.h"
#include "break.spv.h"
#include "fcmp.spv.h"
#include "float.spv.h"
#include "ifelse.spv.h"
#include "julia.spv.h"
#include "juliapc.spv.h"
#include "palette.spv.h"
#include "palette_hoist.spv.h"
#include "palette_nopc.spv.h"
#include "twobreak.spv.h"
#include "loop.spv.h"

static uint32_t ref_basic(uint32_t i) { return 2 * i + 1; }
static uint32_t ref_float(uint32_t i) { return (uint32_t)((float)i * 1.5f + 0.5f); }
static uint32_t ref_ifelse(uint32_t i) { return (i & 1) ? i * 3 : i >> 1; }
static uint32_t ref_loop(uint32_t i)
{
	uint32_t c = 0;

	for (uint32_t k = 0; k < (i & 15); k++)
		c += k;
	return c;
}
static uint32_t ref_break(uint32_t i)
{
	uint32_t k = 0;

	for (; k < 100; k++)
		if (k * k >= i)
			break;
	return k;
}
static uint32_t ref_fcmp(uint32_t i) { return (float)i < 100.0f ? 1 : 2; }
static uint32_t ref_twobreak(uint32_t i)
{
	uint32_t k = 0;

	for (; k < 100; k++) {
		if (k * k >= i)
			break;
		if (k == 9)
			break;
	}
	return k;
}
static uint32_t ref_julia(uint32_t i)
{
	float zx = ((float)(i & 63) - 32.0f) * 0.05f, zy = ((float)(i >> 6) - 32.0f) * 0.05f;
	uint32_t n = 0;

	for (; n < 32; n++) {
		float xx = zx * zx, yy = zy * zy;

		if (xx + yy > 16.0f)
			break;
		zy = 2.0f * zx * zy + 0.156f;
		zx = xx - yy - 0.8f;
	}
	return n;
}

static uint32_t ref_juliapc(uint32_t i)
{
	float zx = ((float)(i & 63) - 32.0f) * 0.05f, zy = ((float)(i >> 6) - 32.0f) * 0.05f;
	uint32_t n = 0;

	for (; n < 32; n++) {
		float xx = zx * zx, yy = zy * zy;

		if (xx + yy > 16.0f)
			break;
		zy = 2.0f * zx * zy + 0.5f;
		zx = xx - yy - 1.5f * 0.5f;
	}
	return n;
}
static uint32_t ref_palette(uint32_t i)
{
	uint32_t n = i & 255, col = 0;

	if (n < 128) {
		uint32_t k = (n * 7u + (uint32_t)(0.5f * 255.0f)) & 255u;
		float g = (float)n * 4.0f;
		uint32_t glow = (uint32_t)(g < 255.0f ? g : 255.0f);

		col = k << 16 | ((k * 3u) & 255u) << 8 | (255u - k > glow ? 255u - k : glow);
	}
	return 0xff000000u | col;
}

static const struct {
	const char *name;
	const uint32_t *spv;
	size_t size;
	uint32_t (*ref)(uint32_t);
} tests[] = {
#define T(n) { #n, n##_spv, sizeof(n##_spv), ref_##n }
	T(basic), T(float), T(ifelse), T(loop), T(break), T(fcmp), T(twobreak), T(julia), T(juliapc), T(palette),
	{ "palette_nopc", palette_nopc_spv, sizeof(palette_nopc_spv), ref_palette },
	{ "palette_hoist", palette_hoist_spv, sizeof(palette_hoist_spv), ref_palette },
#undef T
};

#define CHECK(x)                                                         \
	do {                                                             \
		VkResult r_ = (x);                                       \
		if (r_ != VK_SUCCESS) {                                  \
			fprintf(stderr, "%s: %d\n", #x, r_);             \
			exit(1);                                         \
		}                                                        \
	} while (0)

int main(int argc, char **argv)
{
	const char *name = argc > 1 ? argv[1] : "basic";
	uint32_t groups = argc > 2 ? strtoul(argv[2], NULL, 0) : 64, n = 64 * groups;
	const float push[2] = { 1.5f, 0.5f };
	unsigned t;

	for (t = 0; t < sizeof(tests) / sizeof(tests[0]); t++)
		if (!strcmp(tests[t].name, name))
			break;
	if (t == sizeof(tests) / sizeof(tests[0])) {
		fprintf(stderr, "unknown test %s\n", name);
		return 2;
	}
	VkDeviceSize size = 4 * (VkDeviceSize)n;
	VkInstance instance;
	VkPhysicalDevice pdev;
	VkDevice dev;
	VkQueue queue;
	uint32_t count = 1, mem_type = UINT32_MAX, bad = 0, i;

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
		    (props.memoryTypes[i].propertyFlags &
		     (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
			    (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
			mem_type = i;
			break;
		}
	CHECK(vkAllocateMemory(dev, &(VkMemoryAllocateInfo){
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = req.size, .memoryTypeIndex = mem_type }, NULL, &mem));
	CHECK(vkBindBufferMemory(dev, buf, mem, 0));
	CHECK(vkMapMemory(dev, mem, 0, size, 0, (void **)&map));
	for (i = 0; i < n; i++)
		map[i] = 0xabadbeef;

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
			VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(push) } }, NULL, &layout));
	CHECK(vkCreateShaderModule(dev, &(VkShaderModuleCreateInfo){
		.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = tests[t].size, .pCode = tests[t].spv },
		NULL, &module));
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

	CHECK(vkCreateCommandPool(dev, &(VkCommandPoolCreateInfo){
		.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO }, NULL, &cpool));
	CHECK(vkAllocateCommandBuffers(dev, &(VkCommandBufferAllocateInfo){
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 }, &cmd));
	CHECK(vkBeginCommandBuffer(cmd, &(VkCommandBufferBeginInfo){
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }));
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
	vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
	vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(push), push);
	vkCmdDispatch(cmd, groups, 1, 1);
	CHECK(vkEndCommandBuffer(cmd));
	CHECK(vkCreateFence(dev, &(VkFenceCreateInfo){
		.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }, NULL, &fence));
	CHECK(vkQueueSubmit(queue, 1, &(VkSubmitInfo){
		.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
		.pCommandBuffers = &cmd }, fence));
	CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull));

	for (i = 0; i < n; i++)
		if (map[i] != tests[t].ref(i) && !bad++)
			printf("first wrong: d[%u] = %#x, expected %#x\n", i, map[i],
			       tests[t].ref(i));
	printf("%s: %u invocations: %u wrong: %s\n", name, n, bad, bad ? "FAIL" : "PASS");
	return !!bad;
}
