# bench/vs/lcgf-cpp: LCGF's comparison scenes from C++ (ci/jobs/vs-lcgf-bindings.sh).
#   cmake -S bench/vs/lcgf-cpp -B build -DCMAKE_PREFIX_PATH=<zig build abi prefix>
cmake_minimum_required(VERSION 3.20)
project(vs-lcgf-cpp CXX)
find_package(lcgf REQUIRED)
foreach(v IN ITEMS "vs-lcgf-cpp;-O2" "vs-lcgf-cpp-small;-Os")
  list(GET v 0 name)
  list(GET v 1 opt)
  add_executable(${name} main.cpp)
  target_link_libraries(${name} PRIVATE lcgf::lcgf)
  target_compile_options(${name} PRIVATE ${opt})
endforeach()
target_link_options(vs-lcgf-cpp-small PRIVATE -s)
