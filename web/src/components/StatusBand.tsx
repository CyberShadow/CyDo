import { useEffect, useRef } from "preact/hooks";
import { isCompactingStatus } from "./SystemBanner";

let counter = 0;

const TILE_H = 800;

const WORKING_CIRCLES: [number, number, number, number][] = [
  [204, 281, 189, 0.46],
  [739, 89, 195, 0.69],
  [739, 889, 195, 0.69],
  [504, 27, 117, 0.5],
  [504, 827, 117, 0.5],
  [317, 603, 173, 0.61],
  [612, 348, 217, 0.69],
  [388, 270, 141, 0.73],
  [715, 633, 174, 0.61],
  [448, 464, 99, 0.62],
  [858, 314, 83, 0.46],
  [327, 65, 157, 0.6],
  [327, 865, 157, 0.6],
  [820, 453, 122, 0.58],
  [911, 15, 89, 0.75],
  [911, 815, 89, 0.75],
  [145, 707, 82, 0.64],
  [175, 527, 109, 0.71],
  [871, 650, 98, 0.6],
  [473, 624, 121, 0.51],
  [138, 55, 102, 0.75],
  [138, 855, 102, 0.75],
  [581, 720, 86, 0.74],
  [906, 219, 81, 0.58],
  [89, 177, 81, 0.48],
  [587, 123, 80, 0.63],
  [588, 570, 83, 0.62],
  [766, 291, 83, 0.72],
];

const ENDING_CIRCLES: [number, number, number, number][] = [
  [402, 693, 162, 0.79],
  [402, -107, 162, 0.79],
  [230, 675, 162, 0.58],
  [230, -125, 162, 0.58],
  [782, 362, 188, 0.68],
  [264, 304, 213, 0.62],
  [533, 273, 116, 0.58],
  [574, 674, 151, 0.69],
  [864, 567, 100, 0.55],
  [503, 121, 82, 0.66],
  [130, 421, 82, 0.78],
  [755, 74, 178, 0.79],
  [755, 874, 178, 0.79],
  [598, 408, 94, 0.74],
  [701, 653, 99, 0.51],
  [528, 495, 94, 0.72],
  [212, 87, 109, 0.46],
  [405, 137, 96, 0.52],
  [422, 473, 104, 0.5],
  [886, 133, 84, 0.73],
  [637, 205, 106, 0.63],
  [659, 520, 86, 0.79],
  [825, 697, 90, 0.68],
  [126, 191, 90, 0.65],
  [429, 285, 93, 0.7],
  [90, 55, 81, 0.72],
  [90, 855, 81, 0.72],
  [610, 61, 85, 0.5],
  [610, 861, 85, 0.5],
  [112, 561, 101, 0.47],
  [328, 39, 85, 0.61],
  [328, 839, 85, 0.61],
];

function buildCircles(
  container: SVGGElement,
  circles: [number, number, number, number][],
  gradId: string,
) {
  const ns = "http://www.w3.org/2000/svg";
  for (const [cx, cy, r, opacity] of circles) {
    const ry = (r * TILE_H) / 1000;
    for (const offset of [-TILE_H, 0, TILE_H]) {
      const el = document.createElementNS(ns, "ellipse");
      el.setAttribute("cx", String(cx));
      el.setAttribute("cy", String(cy + offset));
      el.setAttribute("rx", String(r));
      el.setAttribute("ry", String(ry));
      el.setAttribute("fill", `url(#${gradId})`);
      el.setAttribute("opacity", String(opacity));
      container.appendChild(el);
    }
  }
}

function buildCompacting(container: SVGGElement, gradId: string) {
  const ns = "http://www.w3.org/2000/svg";
  const CX_L = 250,
    CX_R = 750,
    RX = 350,
    RY = 52;
  const cos45 = Math.cos(Math.PI / 4);

  for (let i = 0; i < 8; i++) {
    const cy = (TILE_H / 8) * (i + 0.5);
    const sides: [number, number][] = [
      [CX_L, 45],
      [CX_R, -45],
    ];
    for (const [cx, angle] of sides) {
      const ellipses: [number, number][] = [[cx, cy]];
      // Wrapping duplicates
      const reach = RX * cos45;
      if (cy - reach < 0) ellipses.push([cx, cy + TILE_H]);
      if (cy + reach > TILE_H) ellipses.push([cx, cy - TILE_H]);

      for (const offset of [-TILE_H, 0, TILE_H]) {
        for (const [ecx, ecy] of ellipses) {
          const el = document.createElementNS(ns, "ellipse");
          el.setAttribute("cx", String(ecx));
          el.setAttribute("cy", String(ecy + offset));
          el.setAttribute("rx", String(RX));
          el.setAttribute("ry", String(RY));
          el.setAttribute(
            "transform",
            `rotate(${angle},${ecx},${ecy + offset})`,
          );
          el.setAttribute("fill", `url(#${gradId})`);
          el.setAttribute("opacity", "0.7");
          container.appendChild(el);
        }
      }
    }
  }
}

function buildRequesting(container: SVGGElement, gradId: string) {
  const ns = "http://www.w3.org/2000/svg";
  const ellipses: [number, number, number, number, number][] = [
    [1000, 400, 120, 2000, 0.85],
    [1000, 400, 200, 2000, 0.3],
  ];
  for (const [cx, cy, rx, ry, opacity] of ellipses) {
    const el = document.createElementNS(ns, "ellipse");
    el.setAttribute("cx", String(cx));
    el.setAttribute("cy", String(cy));
    el.setAttribute("rx", String(rx));
    el.setAttribute("ry", String(ry));
    el.setAttribute("fill", `url(#${gradId})`);
    el.setAttribute("opacity", String(opacity));
    container.appendChild(el);
  }
}

export function deriveBandStatus(
  sessionStatus: string | null | undefined,
  isProcessing: boolean,
  stdinClosed: boolean,
  alive: boolean,
): string {
  if (alive && stdinClosed) return "ending";
  if (sessionStatus) {
    if (isCompactingStatus(sessionStatus)) return "compacting";
    if (sessionStatus.trim().toLowerCase() === "requesting")
      return "requesting";
  }
  if (isProcessing) return "working";
  return "idle";
}

export function StatusBand({ status }: { status: string }) {
  const svgRef = useRef<SVGSVGElement>(null);
  const gradId = useRef(`sb-grad-${++counter}`).current;

  useEffect(() => {
    const svg = svgRef.current;
    if (!svg) return;

    const workingLayer = svg.querySelector<SVGGElement>(
      ".sb-layer-working .sb-scan-group",
    );
    const endingLayer = svg.querySelector<SVGGElement>(
      ".sb-layer-ending .sb-scan-group",
    );
    const compactingLayer = svg.querySelector<SVGGElement>(
      ".sb-layer-compacting .sb-scan-group",
    );
    const requestingLayer = svg.querySelector<SVGGElement>(
      ".sb-layer-requesting .sb-sweep-group",
    );

    if (workingLayer) buildCircles(workingLayer, WORKING_CIRCLES, gradId);
    if (endingLayer) buildCircles(endingLayer, ENDING_CIRCLES, gradId);
    if (compactingLayer) buildCompacting(compactingLayer, gradId);
    if (requestingLayer) buildRequesting(requestingLayer, gradId);
  }, [gradId]);

  return (
    <svg
      ref={svgRef}
      class="status-band"
      data-status={status}
      preserveAspectRatio="none"
      viewBox="0 0 1000 1"
    >
      <defs>
        <radialGradient
          id={gradId}
          gradientUnits="objectBoundingBox"
          cx="0.5"
          cy="0.5"
          r="0.5"
        >
          <stop offset="0%" stop-color="var(--status-color)" stop-opacity="1" />
          <stop
            offset="55%"
            stop-color="var(--status-color)"
            stop-opacity="0.25"
          />
          <stop
            offset="100%"
            stop-color="var(--status-color)"
            stop-opacity="0"
          />
        </radialGradient>
      </defs>
      <g class="sb-layer sb-layer-working">
        <g class="sb-scan-group" />
      </g>
      <g class="sb-layer sb-layer-compacting">
        <g class="sb-scan-group" />
      </g>
      <g class="sb-layer sb-layer-requesting">
        <g class="sb-sweep-group" />
      </g>
      <g class="sb-layer sb-layer-ending">
        <g class="sb-scan-group" />
      </g>
    </svg>
  );
}
