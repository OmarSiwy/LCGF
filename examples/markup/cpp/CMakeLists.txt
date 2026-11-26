# examples/markup's page from C++: the same ui/counter.html and ui/counter.css as app.zig.
#   cmake -S examples/markup/cpp -B build -DCMAKE_PREFIX_PATH=<zig build abi prefix>
#   cmake --build build && ./build/example-markup-cpp
cmake_minimum_required(VERSION 3.20)
project(example-markup-cpp CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(lcgf REQUIRED)
add_executable(example-markup-cpp main.cpp)
# Runs lcgf-gen on the page: counter.lcgf.hpp, regenerated when the HTML or its CSS changes.
lcgf_add_ui(example-markup-cpp ../ui/counter.html)
