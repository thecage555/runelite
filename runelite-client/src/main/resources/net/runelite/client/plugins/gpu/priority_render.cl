/*
 * Copyright (c) 2021, Adam <Adam@sigterm.info>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// Calculate adjusted priority for a face with a given priority, distance, and
// model global min10 and face distance averages. This allows positioning faces
// with priorities 10/11 into the correct 'slots' resulting in 18 possible
// adjusted priorities
int priority_map(int p, int distance, int _min10, int avg1, int avg2, int avg3) {
  // (10, 11)  0  1  2  (10, 11)  3  4  (10, 11)  5  6  7  8  9  (10, 11)
  //   0   1   2  3  4    5   6   7  8    9  10  11 12 13 14 15   16  17
  switch (p) {
    case 0:
      return 2;
    case 1:
      return 3;
    case 2:
      return 4;
    case 3:
      return 7;
    case 4:
      return 8;
    case 5:
      return 11;
    case 6:
      return 12;
    case 7:
      return 13;
    case 8:
      return 14;
    case 9:
      return 15;
    case 10:
      if (distance > avg1) {
        return 0;
      } else if (distance > avg2) {
        return 5;
      } else if (distance > avg3) {
        return 9;
      } else {
        return 16;
      }
    case 11:
      if (distance > avg1 && _min10 > avg1) {
        return 1;
      } else if (distance > avg2 && (_min10 > avg1 || _min10 > avg2)) {
        return 6;
      } else if (distance > avg3 && (_min10 > avg1 || _min10 > avg2 || _min10 > avg3)) {
        return 10;
      } else {
        return 17;
      }
    default:
      // this can't happen unless an invalid priority is sent. just assume 0.
      return 0;
  }
}

// calculate the number of faces with a lower adjusted priority than
// the given adjusted priority
int count_prio_offset(__local struct shared_data *shared, int priority) {
  // this shouldn't ever be outside of (0, 17) because it is the return value from priority_map
  priority = clamp(priority, 0, 17);
  int total = 0;
  for (int i = 0; i < priority; i++) {
    total += shared->totalMappedNum[i];
  }
  return total;
}

void get_face(__local struct shared_data *shared, __constant struct uniform *uni, __global const float4 *vb, __global const float4 *tempvb, uint localId,
              struct modelinfo minfo, float cameraYaw, float cameraPitch,
              /* out */ int *prio, int *dis, float4 *o1, float4 *o2, float4 *o3) {
  int size = minfo.size;
  int offset = minfo.offset;
  int flags = minfo.flags;
  uint ssboOffset;

  if (localId < size) {
    ssboOffset = localId;
  } else {
    ssboOffset = 0;
  }

  float4 vertA, vertB, vertC;

  // Grab triangle vertices from the correct buffer
  if (flags < 0) {
    vertA = vb[offset + ssboOffset * 3];
    vertB = vb[offset + ssboOffset * 3 + 1];
    vertC = vb[offset + ssboOffset * 3 + 2];
  } else {
    vertA = tempvb[offset + ssboOffset * 3];
    vertB = tempvb[offset + ssboOffset * 3 + 1];
    vertC = tempvb[offset + ssboOffset * 3 + 2];
  }

  if (localId < size) {
    int orientation = flags & 0x7ff;

    // rotate for model orientation
    float4 rvertA = rotate_vertex(vertA, orientation);
    float4 rvertB = rotate_vertex(vertB, orientation);
    float4 rvertC = rotate_vertex(vertC, orientation);

    // calculate distance to face
    float w = vertA.w;
    int thisPriority = ((*(int *)&w) >> 16) & 0xf;  // all vertices on the face have the same priority
    int thisDistance = face_distance(rvertA, rvertB, rvertC, cameraYaw, cameraPitch);

    *o1 = rvertA;
    *o2 = rvertB;
    *o3 = rvertC;

    *prio = thisPriority;
    *dis = thisDistance;
  } else {
    *o1 = (float4)(0, 0, 0, 0);
    *o2 = (float4)(0, 0, 0, 0);
    *o3 = (float4)(0, 0, 0, 0);
    *prio = 0;
    *dis = 0;
  }
}

void add_face_prio_distance(__local struct shared_data *shared, __constant struct uniform *uni, uint localId, struct modelinfo minfo, float4 rvertA,
                            float4 rvertB, float4 rvertC, int thisPriority, int thisDistance) {
  if (localId < minfo.size) {
    // if the face is not culled, it is calculated into priority distance averages
    int4 pos = (int4)(minfo.x, minfo.y, minfo.z, 0);
    if (face_visible(uni, rvertA, rvertB, rvertC, pos)) {
      atomic_add(&shared->totalNum[thisPriority], 1);
      atomic_add(&shared->totalDistance[thisPriority], thisDistance);

      // calculate minimum distance to any face of priority 10 for positioning the 11 faces later
      if (thisPriority == 10) {
        atomic_min(&shared->min10, thisDistance);
      }
    }
  }
}

int map_face_priority(__local struct shared_data *shared, uint localId, struct modelinfo minfo, int thisPriority, int thisDistance, int *prio) {
  int size = minfo.size;

  // Compute average distances for 0/2, 3/4, and 6/8

  if (localId < size) {
    int avg1 = 0;
    int avg2 = 0;
    int avg3 = 0;

    if (shared->totalNum[1] > 0 || shared->totalNum[2] > 0) {
      avg1 = (shared->totalDistance[1] + shared->totalDistance[2]) / (shared->totalNum[1] + shared->totalNum[2]);
    }

    if (shared->totalNum[3] > 0 || shared->totalNum[4] > 0) {
      avg2 = (shared->totalDistance[3] + shared->totalDistance[4]) / (shared->totalNum[3] + shared->totalNum[4]);
    }

    if (shared->totalNum[6] > 0 || shared->totalNum[8] > 0) {
      avg3 = (shared->totalDistance[6] + shared->totalDistance[8]) / (shared->totalNum[6] + shared->totalNum[8]);
    }

    int adjPrio = priority_map(thisPriority, thisDistance, shared->min10, avg1, avg2, avg3);
    int prioIdx = atomic_add(&shared->totalMappedNum[adjPrio], 1);

    *prio = adjPrio;
    return prioIdx;
  }

  *prio = 0;
  return 0;
}

void insert_face(__local struct shared_data *shared, uint localId, struct modelinfo minfo, int adjPrio, int distance, int prioIdx) {
  int size = minfo.size;

  if (localId < size) {
    // calculate base offset into renderPris based on number of faces with a lower priority
    int baseOff = count_prio_offset(shared, adjPrio);
    // the furthest faces draw first, and have the highest priority.
    // if two faces have the same distance, the one with the
    // lower id draws first.
    shared->renderPris[baseOff + prioIdx] = distance << 16 | (int)(~localId & 0xffffu);
  }
}

int tile_height(read_only image3d_t tileHeightImage, int z, int x, int y) {
#define ESCENE_OFFSET 40  // (184-104)/2
  const sampler_t tileHeightSampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP_TO_EDGE;
  int4 coord = (int4)(x + ESCENE_OFFSET, y + ESCENE_OFFSET, z, 0);
  return read_imagei(tileHeightImage, tileHeightSampler, coord).x << 3;
}

float4 hillskew_vertex(read_only image3d_t tileHeightImage, float4 v, int hillskew, int y, int plane) {
  if (hillskew == 1) {
    float fx = v.x / 128;
    float fz = v.z / 128;
    int sx = (int)(floor(fx));
    int sz = (int)(floor(fz));
    float it;
    float h1 = mix(tile_height(tileHeightImage, plane, sx, sz), tile_height(tileHeightImage, plane, sx + 1, sz), fract(fx, &it));
    float h2 = mix(tile_height(tileHeightImage, plane, sx, sz + 1), tile_height(tileHeightImage, plane, sx + 1, sz + 1), fract(fx, &it));
    float h3 = mix(h1, h2, fract(fz, &it));
    return (float4)(v.x, v.y + (int)(h3)-y, v.z, v.w);
  } else {
    return v;
  }
}

void sort_and_insert(__local struct shared_data *shared, __constant struct uniform *uni, __global const float4 *texb, __global const float4 *temptexb,
                     __global float4 *vout, __global float4 *uvout, uint localId, struct modelinfo minfo, int thisPriority, int thisDistance, float4 rvertA,
                     float4 rvertB, float4 rvertC, read_only image3d_t tileHeightImage) {
  int size = minfo.size;

  if (localId < size) {
    int outOffset = minfo.idx;
    int toffset = minfo.toffset;
    int flags = minfo.flags;

    // we only have to order faces against others of the same priority
    const int priorityOffset = count_prio_offset(shared, thisPriority);
    const int numOfPriority = shared->totalMappedNum[thisPriority];
    const int start = priorityOffset;                // index of first face with this priority
    const int end = priorityOffset + numOfPriority;  // index of last face with this priority
    const int renderPriority = thisDistance << 16 | (int)(~localId & 0xffffu);
    int myOffset = priorityOffset;

    // calculate position this face will be in
    for (int i = start; i < end; ++i) {
      if (renderPriority < shared->renderPris[i]) {
        ++myOffset;
      }
    }

    // position into scene
    float4 pos = (float4)(minfo.x, minfo.y, minfo.z, 0);
    rvertA += pos;
    rvertB += pos;
    rvertC += pos;

    // apply hillskew
    int plane = (flags >> 24) & 3;
    int hillskew = (flags >> 26) & 1;
    rvertA = hillskew_vertex(tileHeightImage, rvertA, hillskew, minfo.y, plane);
    rvertB = hillskew_vertex(tileHeightImage, rvertB, hillskew, minfo.y, plane);
    rvertC = hillskew_vertex(tileHeightImage, rvertC, hillskew, minfo.y, plane);

    // write to out buffer
    vout[outOffset + myOffset * 3] = rvertA;
    vout[outOffset + myOffset * 3 + 1] = rvertB;
    vout[outOffset + myOffset * 3 + 2] = rvertC;

    if (toffset < 0) {
      uvout[outOffset + myOffset * 3] = (float4)(0, 0, 0, 0);
      uvout[outOffset + myOffset * 3 + 1] = (float4)(0, 0, 0, 0);
      uvout[outOffset + myOffset * 3 + 2] = (float4)(0, 0, 0, 0);
    } else {
      float4 texA, texB, texC;

      if (flags >= 0) {
        texA = temptexb[toffset + localId * 3];
        texB = temptexb[toffset + localId * 3 + 1];
        texC = temptexb[toffset + localId * 3 + 2];
      } else {
        texA = texb[toffset + localId * 3];
        texB = texb[toffset + localId * 3 + 1];
        texC = texb[toffset + localId * 3 + 2];
      }

      int orientation = flags & 0x7ff;
      uvout[outOffset + myOffset * 3] = (float4)(texA.x, rotate_vertex((float4)(texA.yzw, 0), orientation).xyz + pos.xyz);
      uvout[outOffset + myOffset * 3 + 1] = (float4)(texB.x, rotate_vertex((float4)(texB.yzw, 0), orientation).xyz + pos.xyz);
      uvout[outOffset + myOffset * 3 + 2] = (float4)(texC.x, rotate_vertex((float4)(texC.yzw, 0), orientation).xyz + pos.xyz);
    }
  }
}
