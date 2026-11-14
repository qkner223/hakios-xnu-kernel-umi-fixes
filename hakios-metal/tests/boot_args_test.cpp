#include "test.hpp"
#include "../../userland/src/HakiosMetalBootArgs.h"

TEST(boot_arguments_match_complete_tokens_and_continue_after_substring_matches) {
    CHECK(hm_boot_arg_token("metal=1 al=1 metal_big=1", "al=1"));
    CHECK(!hm_boot_arg_token("metal=1 metal_big=10 xmetal_big=1", "metal_big=1"));
    CHECK(!hm_boot_arg_token("metal=1", "al=1"));
    CHECK(!hm_boot_arg_token("metal_gpu=1", "gpu=1"));
    CHECK(hm_boot_arg_token("metal_gpu=1 gpu=1", "gpu=1"));
    CHECK(hm_boot_arg_token("metal_big=10  metal_big=1 ", "metal_big=1"));
    CHECK(hm_boot_arg_token("\tmetal_big=1\n", "metal_big=1"));
    CHECK(hm_boot_arg_token("metal_nospec", "metal_nospec"));
    CHECK(!hm_boot_arg_token("metal_nospec=1", "metal_nospec"));
    CHECK(!hm_boot_arg_token("", "gpu=1"));
    CHECK(!hm_boot_arg_token("   ", ""));
}
