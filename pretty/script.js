// script.js
let count = 0;
document.getElementById('btn').addEventListener('click', () => {
    count++;
    document.getElementById('output').textContent = 'clicked ' + count + ' times';
});
