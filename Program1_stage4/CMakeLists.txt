cmake_minimum_required(VERSION 3.16)
project(Program1_stage4)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  add_compile_options(-Wall -Wextra -Wpedantic -O2)
endif()

find_package(Threads REQUIRED)

add_executable(program1 src/main.cpp)
target_link_libraries(program1 PRIVATE Threads::Threads)
