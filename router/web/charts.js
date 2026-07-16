import uPlot from './vendor/uPlot.esm.js';
import {formatRate} from './logic.js';

const COLORS = ['#42d3ff', '#58e09c', '#ffbd5c', '#ef6b73'];

export function chartData(aligned) {
  const data = [aligned.timestamps];
  const series = [];
  const bands = [];
  for (const [index, item] of aligned.series.entries()) {
    const color = COLORS[index % COLORS.length];
    const hasBand = item.min.some(value => value !== null) && item.max.some(value => value !== null);
    if (hasBand) {
      const low = data.push(item.min) - 1;
      const high = data.push(item.max) - 1;
      series.push({label: `${item.name} min`, stroke: color, width: 0, show: false});
      series.push({label: `${item.name} max`, stroke: color, width: 0, show: false});
      bands.push({series: [low, high], fill: `${color}20`});
    }
    data.push(item.values);
    series.push({label: item.name, stroke: color, width: 2, spanGaps: true});
  }
  return {data, series, bands};
}

const decimal = (value, suffix) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return '—';
  const separator = suffix === '%' ? '' : ' ';
  return `${number.toFixed(Math.abs(number) >= 100 ? 0 : 1)}${separator}${suffix}`;
};

export function axisTickLabels(kind, values) {
  return values.map(value => {
    if (kind === 'throughput') return formatRate(value);
    if (kind === 'loss') return decimal(Number(value) * 100, '%');
    if (kind === 'power') return decimal(value, 'W');
    return decimal(value, 'ms');
  });
}

export function chartStructureKey(aligned, kind = '') {
  const shape = (aligned?.series || []).map(item => [
    item.name,
    item.min?.some(value => value !== null) && item.max?.some(value => value !== null),
  ]);
  return JSON.stringify([kind, shape]);
}

function valueAxis(kind) {
  const sizes = {throughput: 92, latency: 66, loss: 60, power: 58};
  return {
    stroke: '#7890a4',
    grid: {stroke: '#7890a422'},
    size: sizes[kind] || 66,
    values: (_plot, splits) => axisTickLabels(kind, splits),
  };
}

export function mountChart(element, aligned, options = {}) {
  const prepared = chartData(aligned);
  const height = options.height || 240;
  const structureKey = chartStructureKey(aligned, options.kind);
  const plot = new uPlot({
    width: Math.max(320, element.clientWidth), height,
    cursor: {drag: {x: true, y: false}}, legend: {show: true},
    scales: {x: {time: true}},
    axes: [{stroke: '#7890a4', grid: {stroke: '#7890a422'}}, valueAxis(options.kind)],
    series: [{label: 'time'}, ...prepared.series], bands: prepared.bands,
  }, prepared.data, element);
  const observer = new ResizeObserver(entries => {
    const width = Math.floor(entries[0]?.contentRect.width || element.clientWidth);
    if (width > 0) plot.setSize({width, height});
  });
  observer.observe(element);
  return {
    plot,
    observer,
    update(nextAligned, nextOptions = {}) {
      if ((nextOptions.height || 240) !== height || chartStructureKey(nextAligned, nextOptions.kind) !== structureKey) return false;
      plot.setData(chartData(nextAligned).data);
      return true;
    },
    destroy() { observer.disconnect(); plot.destroy(); },
  };
}
