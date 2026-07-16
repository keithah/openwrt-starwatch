import uPlot from './vendor/uPlot.esm.js';

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

export function mountChart(element, aligned, options = {}) {
  const prepared = chartData(aligned);
  const plot = new uPlot({
    width: Math.max(320, element.clientWidth), height: options.height || 240,
    cursor: {drag: {x: true, y: false}}, legend: {show: true},
    scales: {x: {time: true}},
    axes: [{stroke: '#7890a4', grid: {stroke: '#7890a422'}}, {stroke: '#7890a4', grid: {stroke: '#7890a422'}}],
    series: [{label: 'time'}, ...prepared.series], bands: prepared.bands,
  }, prepared.data, element);
  const observer = new ResizeObserver(entries => {
    const width = Math.floor(entries[0]?.contentRect.width || element.clientWidth);
    if (width > 0) plot.setSize({width, height: options.height || 240});
  });
  observer.observe(element);
  return {plot, observer, destroy() { observer.disconnect(); plot.destroy(); }};
}
