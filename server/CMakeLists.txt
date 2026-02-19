cmake_minimum_required(VERSION 3.16)
project(omphalos_server CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Release build by default; override with -DCMAKE_BUILD_TYPE=Debug
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_compile_options(
  -Wall -Wextra -Wpedantic
  $<$<CONFIG:Release>:-O3>
  $<$<CONFIG:Release>:-march=native>
  $<$<CONFIG:Release>:-funroll-loops>
  $<$<CONFIG:Debug>:-g>
  $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)
add_link_options(
  $<$<CONFIG:Debug>:-fsanitize=address,undefined>
)

# pthreads required for std::thread
find_package(Threads REQUIRED)

add_executable(omphalos_tcp_server
  src/tcp_main.cpp
  src/tcp_server.cpp
)

target_include_directories(omphalos_tcp_server PRIVATE src)
target_link_libraries(omphalos_tcp_server PRIVATE Threads::Threads)

install(TARGETS omphalos_tcp_server DESTINATION bin)
