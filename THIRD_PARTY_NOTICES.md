# 第三方组件声明

本工程零三方 ArkTS 依赖。以下为随工程一起分发的第三方资源及其许可。

## CryptoJS 4.1.1

- 文件：`entry/src/main/resources/rawfile/vendor/crypto-js.min.js`
- 来源：npm `crypto-js@4.1.1`，经 jsDelivr + Terser 压缩（文件头部保留了来源说明）
- 用途：为音源脚本沙箱提供加解密能力
- 许可证：**MIT**
- 上游许可全文：https://github.com/brix/crypto-js/blob/develop/LICENSE

由于上游压缩文件未内嵌许可文本，此处附上 MIT 许可证条款：

```
MIT License

Copyright (c) CryptoJS contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 其余 rawfile 文件

- `rawfile/lx_bridge.html`：本项目自行实现的 ArkWeb 音源沙箱页面（洛雪音源 v2 事件协议）
- `rawfile/vendor/mf_runtime.js`：本项目自行实现的 MusicFree 插件协议装载与依赖注入适配层

二者均为本项目原创代码，不含从第三方项目复制的源码；仅实现协议兼容，不分发任何第三方音源脚本或音乐内容。
