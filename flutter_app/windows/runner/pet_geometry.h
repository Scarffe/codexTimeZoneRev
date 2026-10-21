#ifndef RUNNER_PET_GEOMETRY_H_
#define RUNNER_PET_GEOMETRY_H_
#include <windows.h>
#include <algorithm>
#include <cstdlib>

namespace pet_geometry {
inline int Scale(int value,UINT dpi) {
  return MulDiv(value,static_cast<int>(std::clamp(dpi,48u,768u)),96);
}
inline RECT Fit(RECT position,RECT area,int width,int height,bool dock,int snap) {
  LONG x=position.left,y=position.top;
  if(dock) x=std::abs(x-area.left)<=std::abs(x+width-area.right) ? area.left : area.right-width;
  if(snap>0) {
    if(std::abs(x-area.left)<snap) x=area.left;
    if(std::abs(x+width-area.right)<snap) x=area.right-width;
    if(std::abs(y-area.top)<snap) y=area.top;
    if(std::abs(y+height-area.bottom)<snap) y=area.bottom-height;
  }
  x=std::clamp(x,area.left,std::max(area.left,area.right-width));
  y=std::clamp(y,area.top,std::max(area.top,area.bottom-height));
  return RECT{x,y,x+width,y+height};
}
}
#endif
