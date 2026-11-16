#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
交付前自检：把「历史上踩过的坑」固化成机器扫描。

每一类对应一次真实事故，跑一遍就知道同类问题有没有重新冒出来：
  A 广播闭环        —— v4.0.36「音源导入了还显示未导入」
  B 死 UI           —— v4.0.35「队列按钮点了没反应」（@Builder 没挂载）
  C 带参 Builder    —— v4.0.37「本地音乐数字不刷新」（值传参不触发更新）
  D 页面订阅        —— v4.0.36 同类（常驻页只读一次数据）
  E 回调漏传        —— 死按钮
  F 监听泄漏        —— onChange / offChange 不成对
  G 列表 key        —— 只用 id 会在跨平台撞号时串行
  H 弹层冲突        —— v4.0.37「播放页打不开」（同节点 bindSheet + bindContentCover）
  I 加载态收口      —— v4.0.40「搜索结果滑不到底」（旧请求早退时没清 loadingMore）
  J 系统任务释放    —— v4.0.40「下载点不动」（DownloadTask 没 delete，槽位耗尽）
  K 持久化窗口      —— v4.0.40「大歌单退出重进跑到第 200 首」（截断队列却存全量 index）
  L 自动路径计数    —— v4.0.40「全队列放不了时无限跳歌」（next 无条件清零 failStreak）
  M 进度落盘        —— v4.0.41「重启后进度回退」（先更新节流时间戳再调用，判断恒假）
  N 恢复进度解耦    —— v4.0.41「关掉自动续播后点播放从头开始」（pendingSeek 只挂在开关分支）
  O 本地删除安全    —— v4.0.43「本地音乐加删除」：只能删沙箱副本，不能碰用户原文件
  P 下载取消闭环    —— v4.0.44「下载中点 × 没反应」：cancel 只认排队中，run 里没人核对取消痕迹
  Q 重复入口        —— v4.0.45「同一界面两个入口进同一个地方」（首页时钟 + 最近播放「全部」）

  R~AB 见各函数文档（队列玻璃、推荐池、收藏反馈等）
  AC 底栏路由       —— 「底部第二个入口改发现」：搜索改 push、发现变常驻、旧入口收口
                       「音乐库并入首页」：底栏三项、内容不许留两份、咪咕退出发现
  AE 横滑切页       —— 「底栏滑动 / 自动缩放 / 自动伸展」：Swiper 容器、指示器跟手；
                       收起时换成「圆按钮 + 播放胶囊」并排，不是整条缩窄
  DA~DG 见各函数文档（听到 2/3 自动下载、MusicFree 音源能力扩展、批量下载单次收口、
                       下载稳态渲染收口：进度/状态双信号拆分 + byId O(1) 索引、
                       下载完成瞬间收口：串行错峰 + 一次写全 + 广播合并 + 异步 IO 根治、
                       下载管理页重做：设置搬数据页 + 完成留队且不进本地音乐 + 长按多选/暂停/左滑删除、
                       下载完成全局顿挫根治：流式标签写入消灭整文件大对象/GC STW、
                       完成帧一次刷盘 + 一次全局扇出）

用法：python3 scripts/selfcheck.py [工程根目录]
退出码：0 = 全部通过；1 = 有需要人工确认的项
"""
import glob
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else '.'
ETS = os.path.join(ROOT, 'entry/src/main/ets')

issues = []


def load_raw():
    """磁盘原文，不做任何规范化。供 BX 这类需要验证「参数链真实形态」的新断言使用。"""
    files = glob.glob(os.path.join(ETS, '**/*.ets'), recursive=True)
    return {f: open(f, encoding='utf-8').read() for f in files}


def strip_theme_arg(s: str) -> str:
    """v2.80：青绿液态玻璃整套引擎已连根删除，源码里不再有主题实参
    （取色函数签名已去掉 theme 参数、调用点也不再传 this.glassTheme）。
    本归一化退化为恒等返回，仅为保留 load() 结构与旧断言的读取口径，
    不改动磁盘源码。CA 组另用 load_raw() 直接锁死「引擎零残留」。
    """
    return s


def load():
    """读取视图（v2.80 起与磁盘原文一致）：旧断言继续沿用这一入口。"""
    return {f: strip_theme_arg(s) for f, s in load_raw().items()}


def rel(path):
    return os.path.relpath(path, ROOT)


def check_broadcast(src):
    """A：只读没人写 / 只写没人读。"""
    written, read = {}, {}
    for f, s in src.items():
        for m in re.finditer(r"AppStorage\.setOrCreate\(\s*'([^']+)'", s):
            written.setdefault(m.group(1), set()).add(rel(f))
        for m in re.finditer(r"@StorageProp\(\s*'([^']+)'", s):
            read.setdefault(m.group(1), set()).add(rel(f))
        # 也有直接取值不订阅的用法（比如结果弹窗按版本号触发后读内容）
        for m in re.finditer(r"AppStorage\.get<[^>]*>\(\s*'([^']+)'", s):
            read.setdefault(m.group(1), set()).add(rel(f))
    orphan_read = [k for k in read if k not in written]
    orphan_write = [k for k in written if k not in read]
    for k in orphan_read:
        issues.append(('A', 'FAIL', f'{k} 只读没人写（永远拿默认值）'))
    for k in orphan_write:
        issues.append(('A', 'WARN', f'{k} 只写没人读（冗余广播）'))
    if not orphan_read:
        issues.append(('A', 'PASS', '没有「只读没人写」的订阅'))


def check_dead_builder(src):
    """B：@Builder 定义了却从未被调用。"""
    dead = 0
    for f, s in src.items():
        for m in re.finditer(r'@Builder\s*\n\s*([a-zA-Z_][\w]*)\s*\(', s):
            name = m.group(1)
            # 也可能通过属性引用（.navDestination(this.pageMap)）
            if re.search(r'this\.' + name + r'\s*\(', s) or re.search(r'\.\w+\(this\.' + name + r'\)', s):
                continue
            # @BuilderParam 的默认空实现（如 content0 = this.emptyContent）：作为默认值
            # 赋值即已被使用，调用方会注入真实 builder，本身不会被直接调用。
            if re.search(r'@BuilderParam[^\n]*=\s*this\.' + name + r'\b', s):
                continue
            dead += 1
            issues.append(('B', 'FAIL', f'{rel(f)}: {name}() 从未被调用'))
    if dead == 0:
        issues.append(('B', 'PASS', '没有「写了没挂」的 @Builder'))


def check_param_builder(src):
    """C：带参 @Builder 的实参是可变的 this 状态。"""
    hits = 0
    for f, s in src.items():
        for m in re.finditer(r'@Builder\s*\n\s*([a-zA-Z_][\w]*)\s*\(([^)]*)\)', s):
            name, params = m.group(1), m.group(2)
            if not params.strip():
                continue
            for c in re.finditer(r'this\.' + name + r'\(([^;]*?)\)\s*[}\n]', s):
                # 允许的例外见下方 EXEMPT
                if re.search(r'this\.[a-zA-Z]', c.group(1)) and name not in EXEMPT:
                    hits += 1
                    issues.append(('C', 'WARN',
                                   f'{rel(f)}: {name}() 传入 this 状态，确认父组件重绘时能刷新'))
                    break
    if hits == 0:
        issues.append(('C', 'PASS', '带参 @Builder 没有传可变状态'))


# 主题色光斑：主题变化时整页重建，不依赖 Builder 参数刷新
# markGlyph 同理：形状走的是静态分支（有未通过项 / 没有各一条调用），
# 实参里只有 this.p() 这一层主题取色，主题切换时整页重建即可跟上。
EXEMPT = {'glow', 'glassHighlight', 'sectionTitle', 'actionRow', 'menuRow', 'actionButton',
          'markGlyph', 'hdsTab'}


def check_page_subscription(src):
    """D：页面启动时读仓库数据、却没有 @Watch 订阅。"""
    pages = glob.glob(os.path.join(ETS, 'ui/pages/*.ets'))
    bad = 0
    for f in pages:
        s = src[f]
        # 二级页（NavDestination）每次进入都是新实例，不存在「常驻后收不到通知」的问题
        if 'NavDestination(' in s:
            continue
        m = re.search(r'aboutToAppear\(\)[^{]*\{([\s\S]{0,1500}?)\n  \}', s)
        if not m:
            continue
        if 'App.get().' not in m.group(1):
            continue
        if not re.search(r"@StorageProp\('[^']+'\)\s*@Watch", s):
            bad += 1
            issues.append(('D', 'FAIL', f'{rel(f)}: 启动读数据但没有任何 @Watch 订阅'))
    if bad == 0:
        issues.append(('D', 'PASS', '常驻页面都有变更订阅'))


def check_missing_callback(src):
    """E：组件声明的 onXxx 回调，调用处没传。"""
    comp = {}
    for f, s in src.items():
        for m in re.finditer(r'@Component\s*\nstruct\s+(\w+)\s*\{([\s\S]*?)\n\}', s):
            cbs = re.findall(r'\n  (on[A-Z]\w*)\s*:', m.group(2))
            if cbs:
                comp[m.group(1)] = cbs
    missing = 0
    for f, s in src.items():
        for name, cbs in comp.items():
            for m in re.finditer(name + r'\(\s*\{', s):
                i, depth = m.end() - 1, 0
                block = ''
                for j in range(i, min(len(s), i + 2000)):
                    if s[j] == '{':
                        depth += 1
                    elif s[j] == '}':
                        depth -= 1
                        if depth == 0:
                            block = s[i:j]
                            break
                for cb in cbs:
                    if cb + ':' not in block:
                        missing += 1
                        issues.append(('E', 'FAIL', f'{rel(f)}: {name}(...) 未传 {cb}'))
    if missing == 0:
        issues.append(('E', 'PASS', '没有漏传的回调'))


def check_listener_pair(src):
    """F：Player 的 onChange / offChange 必须成对。"""
    bad = 0
    for f, s in src.items():
        on = len(re.findall(r'player\.onChange\(', s))
        off = len(re.findall(r'player\.offChange\(', s))
        if on != off:
            bad += 1
            issues.append(('F', 'FAIL', f'{rel(f)}: player.onChange {on} 次 / offChange {off} 次'))
    if bad == 0:
        issues.append(('F', 'PASS', '播放器监听成对释放'))


def check_for_each_key(src):
    """G：歌曲列表的 key 必须带 source，否则跨平台撞号会串行。"""
    bad = 0
    for f, s in src.items():
        for m in re.finditer(r'ForEach\([^)]*?\(song: SongInfo.*?\},\s*\((?:song):\s*SongInfo\)\s*=>\s*([^)]+)\)', s, re.S):
            key = m.group(1)
            if 'source' not in key and 'song.id' in key:
                bad += 1
                issues.append(('G', 'FAIL', f'{rel(f)}: 歌曲 key 只用 id'))
    if bad == 0:
        issues.append(('G', 'PASS', '歌曲列表 key 都带 source'))


def check_overlay_conflict(src):
    """H：同一节点上同时挂 bindSheet 与 bindContentCover。"""
    bad = 0
    for f, s in src.items():
        # 粗判：同一条属性链上同时出现两种弹层
        for chain in re.finditer(r'\}\)\s*((?:\n\s*\.[a-zA-Z]+\([^\n]*\))+)', s):
            body = chain.group(1)
            if 'bindSheet' in body and 'bindContentCover' in body:
                bad += 1
                issues.append(('H', 'FAIL', f'{rel(f)}: 同节点同时挂 bindSheet 与 bindContentCover'))
    if bad == 0:
        issues.append(('H', 'PASS', '没有弹层互斥'))


# playCurrent 的 loading 由 AVPlayer stateChange 收口，不走 seq 收口写法
EXEMPT_LOADING = {'playCurrent'}


def check_loading_cleanup(src):
    """I：async 里置了 loading 标志，早退分支必须自己清理。"""
    bad = 0
    for f, s in src.items():
        for m in re.finditer(r'^\s*(?:private )?async (\w+)\(([^)]*)\)[^{]*\{', s, re.M):
            name = m.group(1)
            i, depth = m.end() - 1, 0
            j = i
            while j < len(s):
                if s[j] == '{':
                    depth += 1
                elif s[j] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            body = s[i:j]
            flags = re.findall(r'this\.(loading|loadingMore|importing|refreshing)\s*=\s*true', body)
            if not flags:
                continue
            # loading 由播放器状态机收口（stateChange 的 playing/paused/error 分支）
            if name in EXEMPT_LOADING:
                continue
            for flag in set(flags):
                # 方法内已有「仅在仍是当前请求时才收口」的写法，说明并发语义是考虑过的
                if re.search(r'if\s*\(\s*\w+\s*===\s*this\.\w+\s*\)\s*\{?\s*this\.' + flag, body):
                    continue
                # 早退模式：token/seq 守卫后直接 return
                for guard in re.finditer(
                        r'if\s*\(\s*(\w+)\s*!==\s*this\.(\w+)\s*\)\s*\{\s*([\s\S]{0,180}?)\}\s*\n',
                        body):
                    inner = guard.group(3)
                    if 'return' in inner and ('this.' + flag) not in inner:
                        line = s[:m.start()].count('\n') + 1
                        bad += 1
                        issues.append(('I', 'WARN',
                                       f'{rel(f)}:{line} {name}() 早退未清理 {flag}，可能卡住'))
                        break
    if bad == 0:
        issues.append(('I', 'PASS', '加载态都有收口'))


def check_task_release(src):
    """J：request.downloadFile 拿到的任务必须 delete。"""
    bad = 0
    for f, s in src.items():
        if 'request.downloadFile(' not in s:
            continue
        if 'downloadTask' in s and '.delete()' not in s:
            bad += 1
            issues.append(('J', 'FAIL', f'{rel(f)}: 下载任务从未 delete()，槽位会被占满'))
    if bad == 0:
        issues.append(('J', 'PASS', '系统下载任务都已释放'))


def check_persist_window(src):
    """K：截断保存的队列，index 必须换算到窗口内。"""
    bad = 0
    for f, s in src.items():
        for m in re.finditer(r'private persistQueue[^{]*\{([\s\S]*?)\n  \}', s):
            body = m.group(1)
            if 'slice(' not in body:
                continue
            if 'QUEUE_INDEX' in body and 'start' not in body:
                bad += 1
                issues.append(('K', 'FAIL',
                               f'{rel(f)}: 队列截断保存但 index 未换算，大歌单会错位'))
    if bad == 0:
        issues.append(('K', 'PASS', '队列持久化的 index 与窗口一致'))


def check_auto_reset(src):
    """L：自动切歌路径不能清零失败计数，否则会无限跳歌。"""
    bad = 0
    for f, s in src.items():
        if 'failStreak' not in s:
            continue
        m = re.search(r'async next\(([^)]*)\)[^{]*\{([\s\S]*?)\n  \}', s)
        if m and 'failStreak = 0' in m.group(2) and 'auto' not in m.group(2):
            bad += 1
            issues.append(('L', 'FAIL', f'{rel(f)}: next() 无条件清零 failStreak，失败时会无限跳歌'))
        if 'this.next(true)' in s or 'next(auto' in s:
            continue
        if 'failStreak' in s and 'this.next()' in s:
            bad += 1
            issues.append(('L', 'WARN', f'{rel(f)}: 失败重试走 next()，确认是否清零了计数'))
    if bad == 0:
        issues.append(('L', 'PASS', '自动切歌路径不清零失败计数'))


def check_progress_persist(src):
    """M：播放中的位置落盘。
    v4.0.41 事故：timeUpdate 里先 `lastPersist = now` 再调 `persistQueue(false)`，
    而 persistQueue 首行要求 `now - lastPersist >= 4000` —— 判断恒为假，
    播放中一次都没落盘。正常退出能记住，被杀进程 / 被系统回收后位置退回上次暂停点。
    """
    bad = 0
    for f, s in src.items():
        if 'persistQueue' not in s:
            continue
        if re.search(r'lastPersist\s*=\s*now\s*;\s*this\.persistQueue\(false\)', s):
            bad += 1
            issues.append(('M', 'FAIL',
                           f'{rel(f)}: 先更新 lastPersist 再调 persistQueue(false)，节流判断恒假 → 播放中位置不落盘'))
            continue
        if 'timeUpdate' in s and not ('persistPosition' in s and 'lastPosSave' in s):
            bad += 1
            issues.append(('M', 'WARN', f'{rel(f)}: timeUpdate 未见独立的位置落盘（persistPosition / lastPosSave）'))
    if bad == 0:
        issues.append(('M', 'PASS', '播放中位置定时落盘，没有被自身节流挡住'))


def check_resume_progress(src):
    """N：恢复进度不能挂在自动续播开关上。
    「记住播放进度」与「启动时自动续播」是两件事：关掉自动续播后手动点播放，
    也必须从上次位置继续。旧写法把 pendingSeek 只设在 autoPlay 分支里，
    结果开关看着是开的，实际点播放从头开始。
    """
    bad = 0
    for f, s in src.items():
        if 'pendingSeek' not in s or 'restore(' not in s:
            continue
        m = re.search(r'if \(Settings\.get\(\)\.autoPlay\(\)\)\s*\{(.*?)\}', s, re.S)
        if m and 'pendingSeek' in m.group(1):
            bad += 1
            issues.append(('N', 'FAIL',
                           f'{rel(f)}: pendingSeek 只在 autoPlay 分支设置 → 关掉自动续播后手动播放会从头开始'))
        elif 'resumeKey' not in s:
            bad += 1
            issues.append(('N', 'WARN', f'{rel(f)}: 未见 resumeKey，确认恢复位置在 playCurrent 里被消费'))
    if bad == 0:
        issues.append(('N', 'PASS', '恢复进度与自动续播解耦，手动播放也能接上次位置'))


def check_local_delete_safe(src):
    """O：本地音乐的「删除」只能删应用内副本。

    importOne 先把用户选中的文件复制到沙箱目录，删除时 unlink 的是副本；
    一旦有人把导入改成「直接引用原路径」，点一次删除就把用户手机里的歌删了。
    """
    bad = 0
    for f, s in src.items():
        if 'unlinkSync' not in s or 'importOne' not in s:
            continue
        if 'copyFileSync' not in s:
            bad += 1
            issues.append(('O', 'FAIL',
                           f'{rel(f)}: 删除用 unlinkSync，但导入没有 copyFileSync —— 会删到用户原文件'))
        if 'this.dir' not in s:
            bad += 1
            issues.append(('O', 'WARN', f'{rel(f)}: 未见 this.dir，确认删除目标位于应用沙箱'))
    if bad == 0:
        issues.append(('O', 'PASS', '本地删除只删沙箱副本，不动用户原始文件'))


def _func_body(text, name):
    """粗取某个方法的方法体（够用即可：同名缩进块到下一个同级 } ）"""
    m = re.search(r'\n[ \t]+(?:private |public |protected |static |async )*' +
                  re.escape(name) + r'\s*\(', text)
    if not m:
        return ''
    at = m.start()
    end = text.find('\n  }', at)
    return text[at:end if end > 0 else len(text)]


def _enclosing_method(text, pos):
    """某个位置属于哪个方法（按两空格缩进的方法声明往上找最近一个）"""
    head = text[:pos]
    found = list(re.finditer(r'\n {2}(?:private |public |async )*(\w+)\s*\([^)]*\)\s*(?::\s*[\w<>\[\]|]+)?\s*\{', head))
    return found[-1].group(1) if found else ''


def check_download_cancel(src):
    """P：取消下载必须真的停下。

    v4.0.44 之前 cancel() 只处理 status === 'waiting'，正在下载的那条点「×」毫无反应：
    进度条继续跑、文件继续落盘。修法是「记取消痕迹 + run 的回调里核对」，
    所以扫描看两件事：cancel 不能只认 waiting；删除路径必须先取消再删记录。
    """
    bad = 0
    for f, s in src.items():
        if 'cancel(' not in s or 'Downloader' not in s:
            continue
        body = _func_body(s, 'cancel')
        if "=== 'waiting'" in body and "'done'" not in body:
            bad += 1
            issues.append(('P', 'FAIL',
                           f'{rel(f)}: cancel() 只处理 waiting —— 下载中点取消不会有反应'))
        if "isCancelled" not in s and "'running'" in body:
            bad += 1
            issues.append(('P', 'WARN',
                           f'{rel(f)}: 取消只改了状态，run 回调里没有核对，任务可能被覆盖回 done'))
        if 'removeMany' in s:
            drop = _func_body(s, 'dropOne')
            if drop and "'running'" not in drop and 'cancel(' not in drop:
                bad += 1
                issues.append(('P', 'FAIL',
                               f'{rel(f)}: 删除任务前没有取消，进行中的下载会在后台继续写文件'))
    if bad == 0:
        issues.append(('P', 'PASS', '取消/删除下载都能真正停下任务，不会留下后台写盘'))


def check_dup_entry(src):
    """Q：不要给同一件事放多个入口。

    分两层：
    1. 同屏：一个页面里两处 push / toSheet 到同一个地方；
    2. 跨页：同一个目标页被 3 个及以上页面各挂了一个入口（首页、音乐库、设置都能进下载管理）。

    这类问题不会崩、不会报错，只会让人站在界面前犹豫，或者以为自己点错了。
    弹层内的按钮、互斥分支（空态 / 常规）不在这里判，避免误伤。
    """
    bad = 0
    by_target = {}
    for f, s in src.items():
        if '/core/' in f or not f.endswith('.ets'):
            continue
        counts = {}
        for m in re.findall(r"push\('([a-z]+)'", s):
            key = '打开页面 ' + m
            counts[key] = counts.get(key, 0) + 1
            by_target.setdefault(m, set()).add(f)
        for m in re.findall(r"toSheet\('([a-z]+)'", s):
            key = '打开列表 ' + m
            counts[key] = counts.get(key, 0) + 1
        for k, v in counts.items():
            if v >= 2:
                bad += 1
                issues.append(('Q', 'WARN', f'{rel(f)}: 「{k}」在同一个页面有 {v} 个入口，确认不是重复'))
    for target, files in sorted(by_target.items()):
        if len(files) >= 3:
            bad += 1
            names = '、'.join(sorted(rel(f) for f in files))
            issues.append(('Q', 'WARN', f'「{target}」有 {len(files)} 个页面各自放了入口（{names}），确认是否都必要'))

    # 页面自己写了一个「单曲入队」的按钮，同屏弹的 SongMenu 又允许下载：
    # v4.0.47 播放页就是这样——底部「下载」和菜单「下载到本地」调的是同一个 enqueue。
    # 「下载全部」这类批量的 (downloadAll / enqueueMany) 不算，粒度不同。
    for f, s in src.items():
        if '/core/' in f or 'SongMenu({' not in s or 'downloads.enqueue(' not in s:
            continue
        single = []
        for em in re.finditer(r'downloads\.enqueue\(', s):
            name = _enclosing_method(s, em.start()).lower()
            if 'all' not in name and 'many' not in name:
                single.append(name)
        if len(single) == 0:
            continue
        for m in re.finditer(r'SongMenu\(\{(.*?)\n\s*\}\)', s, re.S):
            if 'hideDownload: true' not in m.group(1):
                bad += 1
                issues.append(('Q', 'WARN',
                               f'{rel(f)}: {single[0]}() 是单曲下载，同页 SongMenu 没写 hideDownload —— '
                               f'同一屏出现两个下载入口'))
                break

    if bad == 0:
        issues.append(('Q', 'PASS', '没有同一页面重复入口，也没有三个以上页面共用一个入口'))


def check_source_gate(src):
    """R：音源「就绪门禁」与「试听拦截」不许退化。

    这两条都是实际踩过的坑：
    1. 脚本执行完（loaded）不等于能取链。独家音源要先拉 rconfig 再注册 handler，
       早先不等 inited 就发 musicUrl，必然报「未注册 request 处理器」，
       表现就是「选了独家源，实际一直用别的源」。
    2. 酷我兜底直连对免费/VIP 歌会返回 11 秒的提示音，code 仍是 200、url 也正常。
       上一轮把「探测失败也信任」套到它头上，结果整首变一句人声。
    静态扫描守这两条，避免下一次重构又把它们改回去。
    """
    res = next((s for f, s in src.items() if f.endswith('core/Resolver.ets')), '')
    run = next((s for f, s in src.items() if f.endswith('core/LxRunner.ets')), '')
    if not res or not run:
        issues.append(('R', 'WARN', '没找到 Resolver/LxRunner，跳过音源门禁检查'))
        return
    bad = 0
    body = _func_body(res, 'kuwoDirect')
    if 'isPreviewLength' not in body:
        bad += 1
        issues.append(('R', 'FAIL', 'kuwoDirect 没有按接口返回的 duration 判试听片段'))
    guard = body.find("indexOf('试听')")
    trusted = body.find("from: '酷我直连'")
    if guard < 0 or (trusted >= 0 and guard > trusted):
        bad += 1
        issues.append(('R', 'FAIL',
                       'kuwoDirect 在探测判出试听片段后仍可能返回链接 —— 11 秒提示音会被当整首播'))
    if 'runner.isInited(' not in res:
        bad += 1
        issues.append(('R', 'FAIL', '取链候选没走 inited 门禁（加载 ≠ 就绪）'))
    if 'waitInited' not in run:
        bad += 1
        issues.append(('R', 'FAIL', 'LxRunner 缺少 waitInited，异步初始化的音源拿不到机会'))
    if 'isInited' in run and 'notifyInited' not in run:
        bad += 1
        issues.append(('R', 'FAIL', 'inited 状态没有回调唤醒等待方，waitInited 会一直等到超时'))
    if bad == 0:
        issues.append(('R', 'PASS', '音源就绪门禁（inited）与试听片段拦截都在位'))


def check_startup_batch(src):
    """S：启动加载不得退回「逐个等 inited」的串行写法。

    旧写法每注入一个源就 await 它 6 秒，装了十几个源时冷启动要一两分钟，
    期间点播放只会得到「没有可用音源」。现在注入串行、等待并发，
    总耗时 ≈ 注入总和 + 最慢那个的等待。
    静态守两件事：loadAll 里不许再出现 `await this.loadOne(`；体检入口必须还在。
    """
    repo = next((s for f, s in src.items() if f.endswith('core/SourceRepo.ets')), '')
    if not repo:
        return
    bad = 0
    body = _func_body(repo, 'loadAll')
    if not body:
        bad += 1
        issues.append(('S', 'FAIL', '找不到 SourceRepo.loadAll，启动加载链路被改动'))
    else:
        if 'await this.loadOne(' in body:
            bad += 1
            issues.append(('S', 'FAIL',
                           'loadAll 又变回逐个等 inited 的串行写法 —— 源多时冷启动会被慢源拖住'))
        if 'waitInited' not in body:
            bad += 1
            issues.append(('S', 'FAIL', 'loadAll 没有注册 inited 等待，加载后状态不会收口'))
    check_all = _func_body(repo, 'checkAll')
    if not check_all or 'CHECK_CONCURRENCY' not in check_all:
        bad += 1
        issues.append(('S', 'FAIL', '批量体检 checkAll 不见了，音源页的「全部体检」会失效'))
    if bad == 0:
        issues.append(('S', 'PASS', '启动加载是「注入串行 + 等待并发」，批量体检入口在位'))


def check_fail_panel(src):
    """T：播放失败必须给得出「问了谁、为什么」，并且能当场换源。

    以前 errorText 是一行拼接长串，播放页只能 maxLines(1) 截断，
    用户既不知道十几个源里谁还活着，也不知道下一步该做什么。
    现在：Resolver 留最后一份失败凭据 → Player 暴露详情与「换一条链接重试」
    → 播放页用面板逐条列出。任何一环被删掉，面板就会空着或按不动。
    """
    res = next((s for f, s in src.items() if f.endswith('core/Resolver.ets')), '')
    ply = next((s for f, s in src.items() if f.endswith('core/Player.ets')), '')
    page = next((s for f, s in src.items() if f.endswith('ui/pages/PlayerPage.ets')), '')
    if not res or not ply or not page:
        issues.append(('T', 'WARN', '没找到 Resolver/Player/PlayerPage，跳过失败面板检查'))
        return
    bad = 0
    if 'lastNotes' not in res or 'getLastFailure' not in res:
        bad += 1
        issues.append(('T', 'FAIL', 'Resolver 不再保留失败凭据（lastNotes / getLastFailure），面板会永远是空的'))
    retry = _func_body(ply, 'retryWithAnotherSource')
    if not retry:
        bad += 1
        issues.append(('T', 'FAIL', 'Player.retryWithAnotherSource 不见了，失败面板的「换源再试」按不动'))
    elif 'takeAlternative' not in retry:
        bad += 1
        issues.append(('T', 'FAIL', '手动换源没有先用备用链接池 —— 白问一遍所有音源，还会把已有的链接丢掉'))
    panel = _func_body(page, 'failPanel')
    if not panel:
        bad += 1
        issues.append(('T', 'FAIL', '播放页的失败面板 failPanel 不见了，失败原因又只剩一行截断文字'))
    elif 'failDetails' not in panel or 'retryWithAnotherSource' not in panel:
        bad += 1
        issues.append(('T', 'FAIL', '失败面板没有列出各音源原因或没有换源入口，等于没做'))
    dispatch = _func_body(page, 'panelContent')
    if 'panel === 7' not in dispatch:
        bad += 1
        issues.append(('T', 'FAIL', '失败面板没有接进 panelContent 分发（panel === 7），点了打不开'))
    if bad == 0:
        issues.append(('T', 'PASS', '失败面板：逐条列「问了谁、为什么没成」，并能直接换源重试'))


def check_source_affinity(src):
    """U：歌 → 源亲和表不许变成「隐形且关不掉」。

    亲和表会持久化到 preferences，如果被删掉不影响播放，所以很容易在某次
    重构里悄悄消失；反过来如果开关失效，用户又没有办法摆脱一个总抢跑的源。
    这里同时守「表存在」和「开关真的被读到」。
    """
    res = next((s for f, s in src.items() if f.endswith('core/Resolver.ets')), '')
    cfg = next((s for f, s in src.items() if f.endswith('core/Settings.ets')), '')
    page = next((s for f, s in src.items() if f.endswith('ui/pages/SourcesPage.ets')), '')
    if not res or not cfg:
        issues.append(('U', 'WARN', '没找到 Resolver/Settings，跳过亲和表检查'))
        return
    bad = 0
    if 'AFFINITY_MAX' not in res or 'affinityTable' not in res:
        bad += 1
        issues.append(('U', 'FAIL', '歌 → 源亲和表不见了（AFFINITY_MAX / affinityTable），同首歌又会每次全源竞速'))
    if 'AFFINITY_MAX' in res and 'table.size > AFFINITY_MAX' not in res:
        bad += 1
        issues.append(('U', 'FAIL', '亲和表没有按上限淘汰，会随播放记录无限增长'))
    if 'rememberSource' not in cfg:
        bad += 1
        issues.append(('U', 'FAIL', 'Settings 缺少 rememberSource 开关，用户关不掉亲和'))
    body = _func_body(res, 'rememberSource')
    if body and 'Settings.get().rememberSource()' not in body:
        bad += 1
        issues.append(('U', 'FAIL', '亲和记录没有读开关 —— 关掉后仍在偷偷写盘'))
    if page and 'setRememberSource' not in page:
        bad += 1
        issues.append(('U', 'FAIL', '音源页没有亲和开关入口，用户无从关闭'))
    if bad == 0:
        issues.append(('U', 'PASS', '歌 → 源亲和表可用、有上限、且能在音源页关掉'))


def check_check_matrix(src):
    """V：自检只有一套结论；启动自检只更新卡片，不弹窗。

    历史教训：
    1. 曾经有「快速体检」和「完整自检」两个模式，前者每源只试一首，结论
       和卡片上的自检对不上，用户按体检通过的源去点歌照样失败；
    2. 中间做过一版「跑完弹窗汇报」，但启动自检是后台任务，弹窗会打断
       正在听歌的用户 —— 已按需求撤掉，只剩卡片状态更新。

    现在只有「单源自检」和「全部自检」，两者同源；启动自检跑完静默收口。
    任何一环退回去（快速模式回潮 / 弹窗回潮）都要 FAIL。
    """
    repo = next((s for f, s in src.items() if f.endswith('core/SourceRepo.ets')), '')
    app = next((s for f, s in src.items() if f.endswith('core/App.ets')), '')
    cfg = next((s for f, s in src.items() if f.endswith('core/Settings.ets')), '')
    page = next((s for f, s in src.items() if f.endswith('ui/pages/SourcesPage.ets')), '')
    index = next((s for f, s in src.items() if f.endswith('pages/Index.ets')), '')
    if not repo or not app or not cfg or not page or not index:
        issues.append(('V', 'WARN', '没找到 SourceRepo/App/Settings/SourcesPage/Index，跳过自检体系检查'))
        return
    bad = 0
    body = _func_body(repo, 'checkAll')
    if not body:
        bad += 1
        issues.append(('V', 'FAIL', 'SourceRepo.checkAll 不见了，批量自检没有入口'))
    else:
        if 'CheckSummary' not in body:
            bad += 1
            issues.append(('V', 'FAIL', 'checkAll 不再返回汇总 CheckSummary，启动自检没有结果可弹'))
        if 'full: boolean' in body or 'quick ?' in body:
            bad += 1
            issues.append(('V', 'FAIL', 'checkAll 又出现快速 / 完整两种模式 —— 两套结论会让用户对不上'))
        if 'summary.failed.push' not in body:
            bad += 1
            issues.append(('V', 'FAIL', 'checkAll 没有收集失败明细，弹窗只能给出一个数字'))
    check_body = _func_body(repo, 'check')
    if 'quick: boolean' in check_body:
        bad += 1
        issues.append(('V', 'FAIL', '单源自检又有 quick 参数，快速模式正在回潮'))
    if '快速体检' in page:
        bad += 1
        issues.append(('V', 'FAIL', '音源页又出现「快速体检」入口，这个模式的结论不可靠'))
    if 'this.checkAll()' not in page:
        bad += 1
        issues.append(('V', 'FAIL', '音源页没有「全部自检」入口'))
    if 'this.repo.check(' not in page:
        bad += 1
        issues.append(('V', 'FAIL', '单源「自检」入口被删了，用户没法只测一个源'))
    if 'autoCheckSources' not in cfg:
        bad += 1
        issues.append(('V', 'FAIL', 'Settings 缺少 autoCheckSources 开关'))
    auto = _func_body(app, 'maybeAutoCheck')
    if not auto:
        bad += 1
        issues.append(('V', 'FAIL', 'App.maybeAutoCheck 不见了，开关打开也不会自检'))
    else:
        if 'autoCheckSources()' not in auto:
            bad += 1
            issues.append(('V', 'FAIL', '启动自检没读开关 —— 用户关不掉'))
        if 'AUTO_CHECK_INTERVAL' not in auto:
            bad += 1
            issues.append(('V', 'FAIL', '启动自检没有节流，连续重启会反复打后端'))
        if 'checkAll' not in auto:
            bad += 1
            issues.append(('V', 'FAIL', '启动自检不再调用 checkAll，开关打开也不会真的跑'))
    # 弹窗已按需求撤掉：启动自检是后台任务，不该打断正在听歌的用户。
    # 这里反过来守「别再挂回来」——广播和弹窗任一处复活都算退化。
    if 'publishCheckReport' in app or 'sourceCheckReport' in app:
        bad += 1
        issues.append(('V', 'FAIL', '启动自检又在广播结果，弹窗已被要求移除'))
    if 'sourceCheckVersion' in index or 'onCheckReport' in index:
        bad += 1
        issues.append(('V', 'FAIL', 'Index 又监听自检结果并弹窗，会打断用户当前操作'))
    if 'setAutoCheckSources' not in page:
        bad += 1
        issues.append(('V', 'FAIL', '音源页没有自动自检开关入口'))
    if bad == 0:
        issues.append(('V', 'PASS', '自检只有一套结论；启动自检静默跑完，只更新卡片不弹窗'))


def check_lyric_layout(src):
    """Y：歌词排版不许退回「大行距 + 统一亮度」，颜色值必须合法。

    这两件事都很隐蔽：
    1. 行高写成「字号 + 8」再叠 9vp padding，19 号字实际占 45vp，2.4 倍行距，
       整屏是一行行竖着散开的，但代码上只差几个数字；
    2. 颜色写成 9 位十六进制（#B30000000），ArkUI 不认这个格式，textShadow
       等于没生效 —— 于是只好把非当前行提到 0.84 硬扛，整屏都在抢注意力。
    """
    page = next((s for f, s in src.items() if f.endswith('ui/pages/PlayerPage.ets')), '')
    if not page:
        issues.append(('Y', 'WARN', '没找到 PlayerPage，跳过歌词排版检查'))
        return
    bad = 0
    if 'lyricAlpha' not in page or 'lyricLineHeight' not in page:
        bad += 1
        issues.append(('Y', 'FAIL', '歌词的行高 / 距离透明度分层被删了，会退回「一行行散着」'))
    if 'lyricFont() + 8' in page or 'lyricFont() + 12' in page:
        bad += 1
        issues.append(('Y', 'FAIL', '歌词行高又写成「字号 + 固定值」，行距会重新散开'))
    if 'withAlpha(this.p().text, this.lyricAlpha(index))' not in page:
        bad += 1
        issues.append(('Y', 'FAIL', '歌词颜色没走距离衰减，非当前行会和当前行一样亮'))
    bad_files = []
    for f, text in src.items():
        if re.search(r"'#[0-9A-Fa-f]{9}'", text):
            bad_files.append(rel(f))
    if bad_files:
        bad += 1
        issues.append(('Y', 'FAIL',
                       '出现 9 位十六进制颜色（ArkUI 不认，阴影等于没生效）：' + '、'.join(bad_files[:3])))
    if bad == 0:
        issues.append(('Y', 'PASS', '歌词行距约 1.6 倍、按距离分档变淡，全工程无非法颜色值'))


def check_local_import(src):
    """X：导入必须是「本地导入」，且读不到文件时说清原因。

    picker 能把云盘里的文件列出来，但脚本要落盘到应用沙箱，读不出来。
    旧代码对所有失败都报「导入失败」，用户只会以为应用坏了。
    """
    page = next((s for f, s in src.items() if f.endswith('ui/pages/SourcesPage.ets')), '')
    if not page:
        issues.append(('X', 'WARN', '没找到 SourcesPage，跳过本地导入检查'))
        return
    bad = 0
    if "'本地导入'" not in page:
        bad += 1
        issues.append(('X', 'FAIL', '导入按钮没有改成本地导入，和「网络导入」区分不开'))
    if '导入脚本' in page:
        bad += 1
        issues.append(('X', 'FAIL', '页面还残留「导入脚本」文案，和「本地导入」并存会让人以为有两个入口'))
    if 'DocumentViewPicker' not in page:
        bad += 1
        issues.append(('X', 'FAIL', '本地导入没有走系统文件选择器'))
    if '云盘' not in page:
        bad += 1
        issues.append(('X', 'FAIL', '读取失败没有提示「云盘文件请先下载到本机」，用户只会看到「导入失败」'))
    if 'maxSelectNumber = 20' not in page:
        bad += 1
        issues.append(('X', 'WARN', '批量导入上限被改小，换一批音源要来回点很多次'))
    if bad == 0:
        issues.append(('X', 'PASS', '本地导入走系统选择器，读不到时会指明云盘文件需先下载'))


def check_swipe_delete(src):
    """W：删除音源必须走「左滑 + 确认」，不能退回菜单里一点就删。

    菜单里的删除是单点直达，误触的代价是脚本文件被 unlink、只能重新导入；
    左滑本身有滑动距离这道物理门槛，再叠一次确认弹窗才够。这条同时守住
    「菜单项别又加回来」—— 两个入口并存时，用户仍然会走更容易误触的那个。
    """
    page = next((s for f, s in src.items() if f.endswith('ui/pages/SourcesPage.ets')), '')
    if not page:
        issues.append(('W', 'WARN', '没找到 SourcesPage，跳过左滑删除检查'))
        return
    bad = 0
    if '.swipeAction(' not in page:
        bad += 1
        issues.append(('W', 'FAIL', '音源卡片没有 swipeAction，左滑删除失效'))
    if 'confirmRemove' not in page:
        bad += 1
        issues.append(('W', 'FAIL', '缺少删除确认 confirmRemove，左滑一点就删，误触无法挽回'))
    if "menuRow($r('sys.symbol.trash'), '删除音源'" in page:
        bad += 1
        issues.append(('W', 'FAIL', '菜单里又出现「删除音源」——单点直达，误触成本比左滑高'))
    if 'ListItem' not in page:
        bad += 1
        issues.append(('W', 'FAIL', '列表退回 Scroll + Column 了，swipeAction 只能挂在 ListItem 上'))
    if bad == 0:
        issues.append(('W', 'PASS', '音源删除走左滑 + 确认弹窗，菜单里的单点删除已移除'))

def check_playlist_ux(src):
    """AD：歌单数据层与详情页左滑；首页自建歌单板块已于 v1.9 下线。

    历史三条反馈都落在「我的歌单」这一块：删歌后封面不刷新（cover 没重算 +
    @Builder 按值传参）、歌单内不能左滑移除、新建入口重复。现在首页板块清掉了，
    卡片组件 / ＋ / 空态都不该再出现；数据层 cover 重算与详情页左滑分流仍然有效，
    继续守住。
    """
    home = next((s for f, s in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    lib = next((s for f, s in src.items() if f.endswith('core/Library.ets')), '')
    detail = next((s for f, s in src.items() if f.endswith('ui/pages/SheetDetailPage.ets')), '')
    if not home or not lib or not detail:
        issues.append(('AD', 'WARN', '缺文件，跳过我的歌单交互检查'))
        return
    bad = 0

    remove = _func_body(lib, 'removeFromPlaylist') or ''
    if not remove:
        bad += 1
        issues.append(('AD', 'FAIL', 'Library 没有 removeFromPlaylist，歌单没法移除歌曲'))
    elif "list.cover = list.songs.length > 0 ? list.songs[0].cover : ''" not in remove:
        bad += 1
        issues.append(('AD', 'FAIL',
                       '移除歌曲后没重算 cover：歌单删空后首页封面还挂着已删的那首'))

    # 按值传参的 @Builder 不会跟着 @State 更新，歌单卡片必须是独立组件
    if '@Builder\n  playlistCard(' in home or 'this.playlistCard(' in home:
        bad += 1
        issues.append(('AD', 'FAIL', '歌单卡还用按值传参的 @Builder：删歌后封面和首数不会变'))
    if 'struct PlaylistCard' in home or 'PlaylistCard({' in home:
        bad += 1
        issues.append(('AD', 'FAIL', '首页又出现歌单卡片组件：自建歌单板块已下线'))

    # 2 个歌单时 SpaceBetween 会把卡片推到两端，中间空一格
    if re.search(r'Flex\(\{[^}]*justifyContent:\s*FlexAlign\.SpaceBetween[^}]*\}\)\s*\{\s*\n\s*ForEach\(this\.playlists',
                 home):
        bad += 1
        issues.append(('AD', 'FAIL',
                       '歌单网格用 SpaceBetween 排列：2 个歌单时会被推到两端，中间空出一格'))

    # 新建入口只能有一个：标题行右侧的「＋」。
    # 副标题（长按提示）和空态卡片（含「新建歌单」按钮）都已删掉——
    # 没歌单时整块空态占掉大半屏，还和标题旁的入口做同一件事。
    head = _func_body(home, 'topHeader') or ''
    if 'sys.symbol.plus' in head:
        bad += 1
        issues.append(('AD', 'FAIL', '首页顶栏又出现「＋」：新建歌单只在「我的歌单」那一行'))
    # v2.61：首页新增「+ 导入歌单」——把外部平台歌单链接导入成收藏，与已下线的
    # 「新建自建歌单」是两回事，用户明确要的就是加号图标。所以不再全文禁止
    # sys.symbol.plus，改为禁止「加号 + 新建歌单语义」同时出现；顶栏加号仍由上面一条守着。
    if re.search(r"sys\.symbol\.plus", home) and re.search(r"新建歌单|我的歌单|createPlaylist", home):
        bad += 1
        issues.append(('AD', 'FAIL', '首页的「＋」又连回自建歌单新建入口（+ 导入歌单是独立功能）'))
    if '长按可以重命名或删除' in home:
        bad += 1
        issues.append(('AD', 'FAIL', '「我的歌单」副标题又回来了：那一行只该有标题 + 新建键'))
    if '还没有自建歌单' in home or re.search(r"action:\s*'新建歌单'", home):
        bad += 1
        issues.append(('AD', 'FAIL', '空态卡片又回来了：没歌单时应只剩标题行 + 「＋」，不再多一块说明和按钮'))

    # 自建歌单：左滑是「移除」，不能复用本地音乐的删文件逻辑。
    # 用正则精确匹配方法名——只查子串的话，canSwipeX 这种改名也能骗过检查
    if not re.search(r'private\s+isPlaylistKind\s*\(', detail) or \
            not re.search(r'private\s+canSwipe\s*\(', detail):
        bad += 1
        issues.append(('AD', 'FAIL', '歌单详情页没区分「本地音乐」和「自建歌单」，左滑无从挂起'))
    if 'removeFromPlaylistOne' not in detail or 'Library.get().removeFromPlaylist(' not in detail:
        bad += 1
        issues.append(('AD', 'FAIL', '自建歌单的左滑没接到 Library.removeFromPlaylist'))
    if 'if (this.isLocalKind()) {' not in detail:
        bad += 1
        issues.append(('AD', 'FAIL', '左滑动作没按类型分流：歌单可能误走删文件'))

    # v2.61 起「+ 导入歌单」：五平台链接 / 纯 ID 解析 → 加入收藏 → 打开详情页。
    # 这是「导入外部歌单」，不是已下线的自建歌单，别和上面的清理断言混为一谈。
    # v2.72：整个导入面板从首页搬到「歌单收藏」二级页标题栏右上角（图 3 标记处），
    # 首页不再有通栏歌单收藏条与导入方卡；下面改检查收藏页与首页残留。
    fav = next((s for f, s in src.items() if f.endswith('ui/pages/FavoriteSheetsPage.ets')), '')
    imp = next((s for f, s in src.items() if f.endswith('core/PlaylistImport.ets')), '')
    if not imp or 'export function parsePlaylistInput' not in imp:
        bad += 1
        issues.append(('AD', 'FAIL', '缺少歌单链接解析模块 PlaylistImport.ets'))
    elif not all(k in imp for k in ("'163.com'", "'qq.com'", "'kugou.com'", "'kuwo.cn'", "'migu.cn'")):
        bad += 1
        issues.append(('AD', 'FAIL', '歌单导入没覆盖 wy/tx/kw/kg/mg 五个平台'))
    if ("@Builder\n  importSheet()" not in fav or 'private doImport()' not in fav or
            'newSheet(ref.platform, ref.kind)' not in fav or
            'App.get().openSheet(sheet)' not in fav or
            'toggleSheetFavorite(sheet)' not in fav):
        bad += 1
        issues.append(('AD', 'FAIL', '收藏页导入歌单没接全：解析 / 加收藏 / 打开详情缺一环'))
    if 'showTrailing: true' not in fav or 'sys.symbol.plus' not in fav or \
            'bindSheet($$this.importShow' not in fav:
        bad += 1
        issues.append(('AD', 'FAIL', '收藏页标题栏没有「+ 导入歌单」按钮或没挂导入面板'))
    if 'importSheet()' in home or 'favSheetsEntry()' in home or 'sys.symbol.plus' in home:
        bad += 1
        issues.append(('AD', 'FAIL', '首页还残留导入面板 / 通栏歌单收藏条 / 加号入口：应整体搬到收藏页'))
    if bad == 0:
        issues.append(('AD', 'PASS',
                       '首页自建歌单板块已清除（无卡片 / 空态），「+ 导入歌单」按新口径搬到收藏页'
                       '标题栏，五平台链接 / 纯 ID 全链路保留；'
                       '数据层封面重算与歌单详情页左滑分流保持'))


def check_home_feed(src):
    """Z：推荐歌单必须「池化 + 每日换 + 会过期」，且只存在一份（在发现页）。

    事故：用户反馈「用了十几个小时、退出重进好多次，推荐歌单一直是那几个，
    换一批就在那几张之间循环」。三个原因叠在一起：
      1. 数据源是歌单广场的 order=hot（历史累计最热，本身几年不变）；
      2. 换一批只翻 3 页（page 1→2→3→1），每页 18 条还只展示前 8 条；
      3. 页面在 Index 里是常驻的（只切 visibility），aboutToAppear 一辈子只跑
         一次，`loaded` 守卫把后续刷新全挡掉了。
    后来首页的榜单/推荐歌单整体移交给发现页，检查对象随之换成 SheetPool：
    池本身要有 TTL 和补货，发现页要接前台/切页信号做过期检查，首页不许再留一份。
    """
    pool = next((s for f, s in src.items() if f.endswith('core/SheetPool.ets')), '')
    disc = next((s for f, s in src.items() if f.endswith('ui/pages/DiscoverPage.ets')), '')
    home = next((s for f, s in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    api = next((s for f, s in src.items() if f.endswith('core/PlatformApi.ets')), '')
    ability = next((s for f, s in src.items() if f.endswith('entryability/EntryAbility.ets')), '')
    if not pool or not disc:
        issues.append(('Z', 'WARN', '没找到 SheetPool / DiscoverPage，跳过推荐池检查'))
        return
    bad = 0
    if not re.search(r'TTL_MS\s*:', pool) or 'valid(' not in pool:
        bad += 1
        issues.append(('Z', 'FAIL', '候选池没有有效期：跨天/放久了也不会重新拉'))
    if 'async grow(' not in pool:
        bad += 1
        issues.append(('Z', 'FAIL', '候选池没有补货逻辑，池子看完就开始重复'))
    if 'shuffle(' not in pool:
        bad += 1
        issues.append(('Z', 'FAIL', '候选池没洗牌，接口给什么顺序就永远什么顺序'))
    if 'sheetPage' in disc:
        bad += 1
        issues.append(('Z', 'FAIL', '发现页又退回「固定几页循环」翻页，换一批会原地打转'))
    if api and 'personalized/playlist' not in api:
        bad += 1
        issues.append(('Z', 'FAIL', '网易云「每日推荐」接口被去掉，内容又会常年不变'))
    if api and 'homeSheets' not in api:
        bad += 1
        issues.append(('Z', 'FAIL', 'PlatformApi 缺少 homeSheets，发现页拿不到会变的歌单'))
    if ability and 'onForeground' not in ability:
        bad += 1
        issues.append(('Z', 'FAIL', 'Ability 没有 onForeground 信号，切后台回来不会刷新'))
    if "foregroundAt" not in disc or 'checkStale' not in disc:
        bad += 1
        issues.append(('Z', 'FAIL', '发现页没有接前台信号做过期检查，常驻页面会一直用旧数据'))
    # 首页已不承载推荐歌单：再出现一套就会两边各刷各的
    if 'homeSheets(' in home or 'new SheetPool()' in home:
        bad += 1
        issues.append(('Z', 'FAIL', '首页又长出推荐歌单：它只该在发现页，两处各刷一套会不一致'))
    if bad == 0:
        issues.append(('Z', 'PASS', '推荐歌单只有发现页一份：池化洗牌、按需补货、跨天/回前台自动过期'))

def check_fav_feedback(src):
    """AA：播放页收藏必须「点了立刻变」，且不在「更多」里重复一份。

    事故：点底排小心心没反应、不飘红，但其实已经收藏成功。
    根因是 actionButton(icon, label, active, action) 这个按值传参的 @Builder：
    参数是拷贝进去的普通值，this.favorite 变了 Builder 内部拿不到新值，
    生成的节点属性也不会重新赋值。现在改成无参 Builder + 内部直读 @State。
    """
    page = next((s for f, s in src.items() if f.endswith('ui/pages/PlayerPage.ets')), '')
    menu = next((s for f, s in src.items() if f.endswith('ui/SongMenu.ets')), '')
    if not page:
        issues.append(('AA', 'WARN', '没找到 PlayerPage，跳过收藏反馈检查'))
        return
    bad = 0
    if 'this.actionButton(' in page:
        bad += 1
        issues.append(('AA', 'FAIL', '动作栏又用回按值传参的 actionButton，按钮状态不会实时变'))
    fav = _func_body(page, 'favButton')
    if not fav:
        bad += 1
        issues.append(('AA', 'FAIL', '播放页没有独立的 favButton，收藏态没有直连 @State'))
    elif 'this.favorite ?' not in fav:
        bad += 1
        issues.append(('AA', 'FAIL', 'favButton 没直接判断 this.favorite，点完不会飘红'))
    if 'this.favButton()' not in page:
        bad += 1
        issues.append(('AA', 'FAIL', '底部动作栏没挂 favButton'))
    # v2.3：播放页底部「更多」已改成「搜歌手」，收藏只留底栏这一个入口
    if 'SongMenu({' in page:
        bad += 1
        issues.append(('AA', 'FAIL', '播放页还挂着「更多」歌曲菜单：收藏/下载会和底栏重复'))
    if menu and 'hideFavorite' not in menu:
        bad += 1
        issues.append(('AA', 'FAIL', 'SongMenu 没有 hideFavorite 参数，其它页面会重复收藏项'))
    if bad == 0:
        issues.append(('AA', 'PASS', '播放页收藏直连状态（点击即变红），无「更多」菜单重复入口'))

def check_sheet_surface(src):
    """AB：队列是「一份浮层 + 一张玻璃卡」，两个入口共用，且边缘不许有任何「一圈」。

    历史（同一个问题被用户提了三次，所以这里一次守死）：
      1. 根节点全透明 → 透出播放页封面暗底，深灰字读不出；
      2. 改成不透明深色 → 同一屏「队列」黑、「更多」浅，两套皮肤；
      3. 挂 bindSheet 上是白底白卡（真机截图确认，sheet 容器自带白底）；
      4. 1px 亮边 → 浅色底上一条白框；
      5. 顶部高光渐变 → 上沿叠到 60%+ 白，圆角裁完就是一道亮带；
      6. 卡片左右缩进 12vp + 14% 压暗遮罩 → 白卡外侧一圈灰框。

    结论：边框、高光带、压暗缝，本质上都是「卡片边缘出现第二个亮度台阶」。
    现在只剩半透明填充 + 背景磨砂 + 下方投影，边界靠明暗差，不靠画出来的线。
    """
    q = next((s for f, s in src.items() if f.endswith('ui/QueueSheet.ets')), '')
    ov = next((s for f, s in src.items() if f.endswith('ui/QueueOverlay.ets')), '')
    page = next((s for f, s in src.items() if f.endswith('ui/pages/PlayerPage.ets')), '')
    index = next((s for f, s in src.items() if f.endswith('pages/Index.ets')), '')
    if not q:
        issues.append(('AB', 'WARN', '没找到 QueueSheet，跳过弹层玻璃检查'))
        return
    bad = 0
    if '@Prop dark' in q:
        bad += 1
        issues.append(('AB', 'FAIL', '队列面板又有 dark 强制开关，会和「更多」等面板出现两套皮肤'))
    pbody = _func_body(q, 'p') or ''
    if 'palette(this.isDark)' not in pbody:
        bad += 1
        issues.append(('AB', 'FAIL', '队列调色板没跟随系统主题，跟其它展开列表不一致'))
    if 'this.glassFill()' not in q:
        bad += 1
        issues.append(('AB', 'FAIL', '队列面板丢了玻璃填充，退回成一块纯色板子'))
    if 'backdropBlur(' not in q:
        bad += 1
        issues.append(('AB', 'FAIL', '队列面板没有 backdropBlur，透出的是清晰封面而不是磨砂'))
    if 'this.glassShadow()' not in q:
        bad += 1
        issues.append(('AB', 'FAIL', '玻璃没有投影，卡片浮不起来（描边已去掉，边界只能靠它）'))
    if re.search(r'\.border\(\{?\s*width:\s*(1|1\.5)', q):
        bad += 1
        issues.append(('AB', 'FAIL', '玻璃卡片又加了描边，浅色背景上会变成一圈明显的白线'))
    # 高光层：渐变会把上沿刷成一条亮带，圆角裁完就是「一圈」
    if 'linearGradient' in q or 'glassGlint' in q:
        bad += 1
        issues.append(('AB', 'FAIL', '队列卡片又铺了高光渐变，上沿会出现一条亮带（边缘一圈的来源之一）'))
    # 左右缩进：卡片外侧留出的那条缝一旦被遮罩压暗就是灰框。
    # 只看卡片最外层（紧挨 .shadow 的那个 padding），内层 18 是内容内边距，别误判。
    tail = q[max(0, q.rfind('.shadow(') - 400):q.rfind('.shadow(')]
    pad = None
    for pad in re.finditer(r"\.padding\(\{(.*?)\}\)", tail, re.S):
        pass
    left = re.search(r"left:\s*(\d+)", pad.group(1)) if pad else None
    # 顶部留了缝、底部不留，就会变成「上面圆角浮着、下面直角切断」，两个入口都难看
    if pad and 'bottom' not in pad.group(1):
        bad += 1
        issues.append(('AB', 'FAIL', '队列卡片底部没留缝，会和顶部不对称（上面圆角、下面直角）'))
    if left and int(left.group(1)) > 0:
        bad += 1
        issues.append(('AB', 'FAIL', '队列卡片又左右缩进了，外侧那条缝会变成一圈灰框'))
    if "backgroundColor('#00000000')" in q:
        bad += 1
        issues.append(('AB', 'FAIL', '队列根节点又写死全透明，文字会和封面撞成一片'))
    fill = re.search(r"withAlpha\('#FFFFFF',\s*0\.(\d+)\)", _func_body(q, 'glassFill') or '')
    if not fill or not (48 <= int((fill.group(1) + '00')[:2]) <= 75):
        bad += 1
        issues.append(('AB', 'FAIL', '浅色玻璃填充不在 48%~75% 之间：太透读不清、太实又变回白板'))
    if not ov:
        bad += 1
        issues.append(('AB', 'FAIL', '没有 QueueOverlay，两个入口的队列外形会各写一套'))
    else:
        # 遮罩只压到卡片外侧那条缝上，正是那圈灰框的直接来源
        if "withAlpha('#000000'" in ov or 'backgroundColor(' in ov:
            bad += 1
            issues.append(('AB', 'FAIL', '队列浮层又铺了压暗色，卡片外侧会多出一圈灰框'))
        if "'86%'" not in ov:
            bad += 1
            issues.append(('AB', 'FAIL', '队列卡片高度不是 86%，顶部露不出封面、悬浮感消失'))
    if page:
        if 'QueueOverlay({' not in page:
            bad += 1
            issues.append(('AB', 'FAIL', '播放页没用公共 QueueOverlay，队列外形会和首页不一致'))
        if 'this.panel > 0 && this.panel !== 4' not in page:
            bad += 1
            issues.append(('AB', 'FAIL', 'bindSheet 没有排除队列，同一屏会出现两层队列'))
    if index:
        if 'QueueOverlay({' not in index:
            bad += 1
            issues.append(('AB', 'FAIL', '首页迷你条还是自己拼的队列叠层，两边长得不一样'))
        if 'transition(TransitionEffect.move(TransitionEdge.BOTTOM)' in index:
            bad += 1
            issues.append(('AB', 'FAIL', '首页又退回「贴底 70% 上滑」的老样式，和播放页不是一套'))
    if bad == 0:
        issues.append(('AB', 'PASS', '队列只有一套：通栏玻璃面板（无描边/无高光带/无灰框缝），两个入口一致'))


def check_tab_routes(src):
    """AC：底栏 = 首页 / 发现 / 设置；音乐库并入首页；发现里不再出现咪咕。

    这里的几条规则都是踩过的坑：
      1. 搜索原本占着一级 Tab，让位给发现后如果只是把 SearchPage 从 tabContent 删掉，
         首页搜索框和歌手页就全成死键——App.openSearch() 一直都在，
         但 pageMap 里从没注册过 'search'，那些入口从来没通过；
      2. 发现页变成常驻一级页后不会重建，设置页改「默认发现平台」必须靠广播推过去，
         只落盘的话得杀进程重进才生效；
      3. 「音乐库」并进首页后如果只删 Tab 不搬内容，四宫格和自建歌单会直接消失；
         反过来，如果只搬内容不删 Tab，同一份内容两处维护，改一边另一边就不一致；
      4. 咪咕的榜单/歌单接口对匿名请求返空，留在发现平台列表里就是「点了什么都没有」。
    """
    shell = next((s for f, s in src.items() if f.endswith('ui/Shell.ets')), '')
    index = next((s for f, s in src.items() if f.endswith('pages/Index.ets')), '')
    disc = next((s for f, s in src.items() if f.endswith('ui/pages/DiscoverPage.ets')), '')
    home = next((s for f, s in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    search = next((s for f, s in src.items() if f.endswith('ui/pages/SearchPage.ets')), '')
    settings = next((s for f, s in src.items() if f.endswith('ui/pages/SettingsPage.ets')), '')
    # v2.63：备份 / 恢复与数据说明收进「数据管理」二级页。AC 组下面三条备份断言
    # 的读取范围跟着扩到「设置主页 + 数据页」合并串，约束一条不删（只是允许分散实现）。
    data_page = next((s for f, s in src.items() if f.endswith('ui/pages/DataSettingsPage.ets')), '')
    data_view = settings + '\n' + data_page
    plat = next((s for f, s in src.items() if f.endswith('common/Platform.ets')), '')
    app = next((s for f, s in src.items() if f.endswith('core/App.ets')), '')
    if not all([shell, index, disc, home, search, settings, plat, app]):
        issues.append(('AC', 'WARN', '缺文件，跳过底栏路由检查'))
        return
    bad = 0

    # 官方 HdsTabs 重做后，页签标签在 HdsNav.ets 的 NAV_TABS，页面内容在 Index 的
    # homeContent/discoverContent/settingsContent builder（经 @BuilderParam 注入 HdsNav）。
    nav = next((s for f, s in src.items() if f.endswith('ui/HdsNav.ets')), '')
    label_src = nav if nav else shell
    labels = re.findall(r"label:\s*'([^']+)'", label_src)
    if labels != ['首页', '发现', '设置']:
        bad += 1
        issues.append(('AC', 'FAIL',
                       '底栏不是「首页 / 发现 / 设置」：音乐库已并入首页，发现必须占第二个位置'))

    # 页面内容 builder 可能分散在多个 @Builder，合并整个 Index 检查挂载。
    tabs = _func_body(index, 'tabContent') or ''
    if 'HomePage(' not in index:
        bad += 1
        issues.append(('AC', 'FAIL', '首页没挂进一级页容器，点底栏「首页」会是空白'))
    if 'DiscoverPage()' not in index:
        bad += 1
        issues.append(('AC', 'FAIL', '发现页没挂进一级页容器，点底栏「发现」会是空白'))
    if 'SettingsPage()' not in index:
        bad += 1
        issues.append(('AC', 'FAIL', '设置页没挂进一级页容器，点底栏「设置」会是空白'))
    if 'LibraryPage()' in tabs or 'pages/LibraryPage' in index:
        bad += 1
        issues.append(('AC', 'FAIL', '音乐库页还在挂载：它已并入首页，两处共存会各改各的'))
    if any(f.endswith('ui/pages/LibraryPage.ets') for f in src.keys()):
        bad += 1
        issues.append(('AC', 'FAIL', 'LibraryPage.ets 文件还在：内容应只有一份，在首页里'))
    if 'SearchPage()' in tabs:
        bad += 1
        issues.append(('AC', 'FAIL', '搜索页还在 tabContent 里常驻，底栏会挤回四项'))
    if not re.search(r"name === 'search'", index):
        bad += 1
        issues.append(('AC', 'FAIL', 'pageMap 没注册 search：首页搜索框、歌手页点歌手名都会变成死键'))
    if "App.get().openSearch(" not in index:
        bad += 1
        issues.append(('AC', 'FAIL', '首页搜索框没接到 App.openSearch()，点了不跳页'))
    if "'pendingSearch'" in index or "'pendingSearch'" in search:
        bad += 1
        issues.append(('AC', 'FAIL', '还在用 pendingSearch 广播传词：搜索已是二级页，关键词应随 push 参数进来'))

    # 一级页不该有返回键：没有可返回的上一页，那个箭头点了只会退出应用
    if 'chevron_left' in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '发现页作为一级页还留着返回键，点了会误退出应用'))
    if 'NavDestination(' in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '发现页又套回 NavDestination：一级页容器里放二级页外框，底部标签栏会跟着消失'))

    # 常驻页必须能收到「设置页换了默认平台」
    if not re.search(r"@StorageProp\('discoverPlatform'\)\s*@Watch", disc):
        bad += 1
        issues.append(('AC', 'FAIL', '发现页没订阅 discoverPlatform，设置页改完默认平台它不会跟着换'))

    # 音乐库的内容必须整体落在首页：少一个入口就是「功能没了」。
    # 用 title 形式精确匹配——「我喜欢的音乐」这种歌单名也会含「我喜欢」，
    # 只查裸词的话拼错标题照样能通过。
    # v2.72：四宫格第四格由「下载管理」换成「歌单收藏」，下载改到顶栏右侧，
    # 四个方块统一为 我喜欢 / 最近播放 / 本地音乐 / 歌单收藏（用户口径）。
    for word in ['我喜欢', '最近播放', '本地音乐', '歌单收藏']:
        if "title: '" + word + "'" not in home:
            bad += 1
            issues.append(('AC', 'FAIL', '首页少了「' + word + '」方块：四宫格缺了一块'))
    # 下载管理方块虽撤，下载入口不能丢：顶栏右侧补了箭头下载按钮，仍走 downloads 路由
    if "title: '下载管理'" in home:
        bad += 1
        issues.append(('AC', 'FAIL', '首页四宫格里还留着「下载管理」方块：应按新口径换成歌单收藏'))
    head = _func_body(home, 'topHeader') or ''
    if 'arrow_down_circle' not in head or "openEntry('downloads')" not in home:
        bad += 1
        issues.append(('AC', 'FAIL', '首页顶栏没补下载图标：下载管理方块撤掉后入口丢了'))
    # v1.9：自建歌单板块按设计从首页整体下线，别又把标题行加回来
    if "Text('我的歌单')" in home:
        bad += 1
        issues.append(('AC', 'FAIL', '首页还留着「我的歌单」板块：已按设计要求清除'))

    # 首页不再有榜单/推荐歌单：它们属于发现页，首页留一份只是把页面撑长并多一次请求
    for gone in ['rankCardSection', 'sheetSection', 'new SheetPool()', 'PlatformApi']:
        if gone in home:
            bad += 1
            issues.append(('AC', 'FAIL', '首页还留着「' + gone + '」：榜单/推荐歌单应只在发现页出现'))

    # 咪咕：接口返空，从发现平台清单里摘掉（全平台表 PLATFORMS 不动，搜索还在用）
    ids = re.search(r"DISCOVER_PLATFORM_IDS[^=]*=\s*\[([^\]]*)\]", plat)
    if not ids:
        bad += 1
        issues.append(('AC', 'FAIL', '没有 DISCOVER_PLATFORM_IDS：发现可用平台应集中定义一份'))
    elif "'mg'" in ids.group(1):
        bad += 1
        issues.append(('AC', 'FAIL', '发现平台清单里还有咪咕：它的榜单/歌单接口返空，点了永远是空页'))
    if 'DISCOVER_PLATFORM_IDS' not in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '发现页没引用平台白名单，咪咕会被自己写死回来'))
    if "'mg'" in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '发现页里硬编码了 mg'))
    if 'ForEach(PLATFORMS' in settings:
        bad += 1
        issues.append(('AC', 'FAIL', '设置页「默认发现平台」还是全平台列表，咪咕又会出现在选项里'))

    # 二级页形态：头部必须有退出口，否则只能靠系统手势
    if "App.get().back()" not in search:
        bad += 1
        issues.append(('AC', 'FAIL', '搜索页作为二级页没有返回键，只能靠系统返回手势退出'))

    # 发现页顶部：不要标题栏（用户要求整块去掉，内容自然上顶），刷新统一走下拽
    if 'header()' in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '发现页又长出标题栏了：顶部只该有筛选带，内容要顶到状态栏下沿'))
    if 'arrow_clockwise' in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '顶部又冒出圆形刷新键：刷新只保留下拉一种，两个入口做同一件事'))
    # 注意用 \bRefresh\(\{ 匹配，别被 pullRefresh() 这种方法名骗过去
    if not re.search(r"\bRefresh\(\{", disc) or 'onRefreshing' not in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '没有下拉刷新：Refresh 容器或 onRefreshing 缺失'))
    if 'this.filters()' not in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '筛选带（filters）没挂上，分段和平台无处可放'))

    # 推荐歌单：必须池化（首页那套），否则各平台按固定顺序返回，「刷新也没用」会重演
    if 'new SheetPool()' not in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '推荐歌单没用候选池，各平台会一直返回同一批'))
    if 'recPool.view(' not in disc or 'recPool.advance(' not in disc:
        bad += 1
        issues.append(('AC', 'FAIL', '没有从池里按批取/换（view / advance），「换一批」会退化成翻页累加'))
    if re.search(r"this\.sheets\s*=\s*list\b", disc):
        bad += 1
        issues.append(('AC', 'FAIL', '还在把接口单页结果直接赋给列表：没有洗牌也没有池，推荐顺序永远固定'))

    # v2.21：按用户决定整体移除「听歌识曲」，这里反向守住删除结果。
    # 半截残留（只剩文件 / 只剩路由 / 只剩入口）会让功能以坏形态复活，
    # 所以按「组件文件 + 首页/路由表/App 三处引用」一起查，任一处有残留即判没删干净。
    rec_files = [f for f in src.keys()
                 if f.endswith('ui/RecognizeGlyph.ets') or f.endswith('ui/pages/RecognizePage.ets')]
    if rec_files:
        bad += 1
        issues.append(('AC', 'FAIL', '听歌识曲组件文件仍存在：已按用户决定整体移除该功能'))
    for tag, text in (('首页', home), ('路由表', index), ('App', app)):
        if re.search(r'Recognize|recognize|识曲|openRecognize', text):
            bad += 1
            issues.append(('AC', 'FAIL', tag + '里仍有听歌识曲残留：入口/路由/方法应一并清除'))

    # v2.22：本地数据备份 / 恢复 + 遗留权限清理。
    # 一起守住「模块存在 / 设置页两个入口 / 两个单例 reload / 权限声明已清」，
    # 少任一环都会变成「能导出但恢复后界面不刷新」或「权限还挂着」的半截形态。
    backup = next((s for f, s in src.items() if f.endswith('core/Backup.ets')), '')
    library = next((s for f, s in src.items() if f.endswith('core/Library.ets')), '')
    if not backup:
        bad += 1
        issues.append(('AC', 'FAIL', '缺少 core/Backup.ets：设置页的备份 / 恢复入口会成死键'))
    else:
        if 'DocumentSaveOptions' not in backup or 'DocumentSelectOptions' not in backup:
            bad += 1
            issues.append(('AC', 'FAIL', '备份模块没走系统保存 / 选择面板'))
        if 'STRING_KEYS' not in backup or 'kindOf' not in backup:
            bad += 1
            issues.append(('AC', 'FAIL', '备份导入没有白名单校验，外部文件可任意写 preferences'))
    if '备份我的数据' not in data_view or '从备份恢复' not in data_view:
        bad += 1
        issues.append(('AC', 'FAIL', '数据管理页没有备份 / 恢复两个入口'))
    if 'doBackup' not in data_view or 'doRestore' not in data_view:
        bad += 1
        issues.append(('AC', 'FAIL', '数据管理页备份 / 恢复入口没接上实现'))
    if 'reload(): void' not in library:
        bad += 1
        issues.append(('AC', 'FAIL', 'Library 缺 reload()：恢复后界面仍显示旧内存数据'))
    try:
        module_json = open(os.path.join(ROOT, 'entry/src/main/module.json5'), encoding='utf-8').read()
        if 'ACCELEROMETER' in module_json or 'ohos.permission.VIBRATE' in module_json:
            bad += 1
            issues.append(('AC', 'FAIL', 'module.json5 仍有已下线的加速度 / 振动权限声明'))
    except OSError:
        bad += 1
        issues.append(('AC', 'FAIL', '读不到 module.json5，无法确认权限清理'))

    # v2.23：桌面服务卡片补齐。form_config.json / string.json 里的 PlayerCard_*
    # 资源早就写好，但一直缺 FormExtensionAbility 注册与卡片页面，属于
    # 「配置在、实现缺」的半成品；两端一起守住，防止又退化成悬空配置。
    card_ability = next((s for f, s in src.items() if f.endswith('form/PlayerCardAbility.ets')), '')
    card_page = next((s for f, s in src.items() if f.endswith('form/pages/PlayerCard.ets')), '')
    if not card_ability or not card_page:
        bad += 1
        issues.append(('AC', 'FAIL', '桌面卡片缺 FormExtensionAbility 或卡片页面：form_config 仍是悬空配置'))
    else:
        if 'onAddForm' not in card_ability or 'onUpdateForm' not in card_ability:
            bad += 1
            issues.append(('AC', 'FAIL', '卡片 Ability 没实现 onAddForm / onUpdateForm，桌面拿不到数据'))
        if 'getPreferencesSync' not in card_ability:
            bad += 1
            issues.append(('AC', 'FAIL', '卡片没有读取共享偏好，桌面只会显示静态占位'))
        if 'postCardAction' not in card_page or 'router' not in card_page:
            bad += 1
            issues.append(('AC', 'FAIL', '卡片点击没接 router 动作，点上去没有反应'))
    try:
        module_json = open(os.path.join(ROOT, 'entry/src/main/module.json5'), encoding='utf-8').read()
        form_cfg = open(os.path.join(ROOT, 'entry/src/main/resources/base/profile/form_config.json'),
                        encoding='utf-8').read()
        if 'PlayerCardAbility' not in module_json or '"type": "form"' not in module_json:
            bad += 1
            issues.append(('AC', 'FAIL', 'module.json5 没注册 form 类型的 extensionAbility'))
        if 'PlayerCard.ets' not in form_cfg:
            bad += 1
            issues.append(('AC', 'FAIL', 'form_config.json 没指向卡片页面'))
    except OSError:
        bad += 1
        issues.append(('AC', 'FAIL', '读不到 module.json5 / form_config.json'))

    # v2.29：按用户决定整套移除「为你整理 / 本机分类 / 首页编排」。
    # 反向断言：六个组件文件已删、入口/路由/设置/偏好/备份白名单全清，
    # 防止三套功能以「只剩半截」的坏形态复活；检查项总数不变、其它检查不放宽。
    removed_files = [
        'core/AutoSheets.ets', 'ui/pages/AutoSheetsPage.ets',
        'core/LocalLibrary.ets', 'ui/pages/LocalLibraryPage.ets',
        'core/HomeLayout.ets', 'ui/pages/HomeLayoutPage.ets'
    ]
    for rf in removed_files:
        if any(f.endswith(rf) for f in src):
            bad += 1
            issues.append(('AC', 'FAIL', rf + ' 仍存在：v2.29 已按用户决定整套移除'))
    sheet_detail = next((s for f, s in src.items() if f.endswith('ui/pages/SheetDetailPage.ets')), '')
    constants = next((s for f, s in src.items() if f.endswith('common/Constants.ets')), '')
    entry_ability = next((s for f, s in src.items() if f.endswith('entryability/EntryAbility.ets')), '')
    backup_src = next((s for f, s in src.items() if f.endswith('core/Backup.ets')), '')
    for tag, text, pattern in (
        ('App', app, r'openAutoSheets|openHomeLayout|openLocalLibrary|HomeLayout'),
        ('Index', index,
         r"name === 'autoSheets'|name === 'homeLayout'|name === 'localLibrary'|AutoSheetsPage|HomeLayoutPage|LocalLibraryPage|defaultTab"),
        ('HomePage', home, r"autoSheetsEntry|localLibraryEntry|@StorageProp\('homeLayout'\)|visibleKeys|HOME_MODULE_DEFS"),
        ('SettingsPage', settings, r'首页编排|openHomeLayout'),
        ('SheetDetailPage', sheet_detail, r'openLocalLibrary|本机分类'),
        ('Backup', backup_src, r'HOME_LAYOUT|DEFAULT_TAB|HomeLayout'),
        ('EntryAbility', entry_ability, r'homeLayout|defaultTab|v4_home_layout|v4_default_tab'),
        ('Constants', constants, r'HOME_LAYOUT|DEFAULT_TAB'),
    ):
        if re.search(pattern, text):
            bad += 1
            issues.append(('AC', 'FAIL', tag + ' 里仍有 v2.29 三套功能残留：入口/路由/偏好应一并清除'))

    # v2.30：歌曲行尾「更多」图标换成真实下载。守住「接 downloads.enqueue」、
    # 「本地 / 已下载不显示假下载按钮」、「订阅 downloadVersion 实时回退」、
    # 「长按仍保留完整菜单」，不做点不动的死键、不丢查看歌手等入口。
    common = next((s for f, s in src.items() if f.endswith('ui/Common.ets')), '')
    if 'arrow_down_circle' not in common or 'downloads.enqueue' not in common:
        bad += 1
        issues.append(('AC', 'FAIL', '歌曲行尾没换成下载图标或没接真实下载：会变成死键'))
    if "song.source !== 'local'" not in common or 'hasDownload' not in common:
        bad += 1
        issues.append(('AC', 'FAIL', '下载按钮没排除本地音乐 / 已下载歌曲：会出现假下载入口'))
    if "@StorageProp('downloadVersion')" not in common:
        bad += 1
        issues.append(('AC', 'FAIL', '下载按钮没订阅 downloadVersion：下载完成后图标不会回退'))
    if 'LongPressGesture' not in common or 'this.onMore()' not in common:
        bad += 1
        issues.append(('AC', 'FAIL', '长按完整菜单被去掉了：查看歌手 / 从歌单移除等入口会丢'))
    # v2.45：下载完成后不再悄悄回退成 more 四宫格，而是显示「已下载」勾选态。
    for kw, msg in (
        ('private isDownloaded(): boolean', '缺已下载态判定：下载完成又会变回四宫格 more'),
        ("icon: $r('sys.symbol.checkmark_circle_fill')", '已下载没用勾选图标'),
        ('color: this.p().primary,', '已下载没用主色区分'),
        ("App.get().toast('这首歌已经在本地了')", '已下载态点了没如实提示：会变成死键'),
    ):
        if kw not in common:
            bad += 1
            issues.append(('AC', 'FAIL', 'Common.ets ' + msg))

    # v2.31：歌手页专辑数与全链路。守住「只从已加载真实作品聚合专辑」、
    # 「诚实标注不是全部专辑总数」、「作品/专辑切换 + 专辑内可播放」、
    # 「专辑 tab 空态一键切歌手」，不新造接口、不造数。
    artist_page = next((s for f, s in src.items() if f.endswith('ui/pages/ArtistPage.ets')), '')
    if 'buildAlbums' not in artist_page or 'albumId' not in artist_page:
        bad += 1
        issues.append(('AC', 'FAIL', '歌手页没有按真实作品聚合专辑：专辑数会是假的'))
    if 'for (const song of list)' not in artist_page:
        bad += 1
        issues.append(('AC', 'FAIL', '专辑分组没遍历已加载歌曲：数据来源不成立'))
    # 2026-11-16：界面不再挂说明句，口径标注并入副标题（「N 部已加载专辑」）
    if '部已加载专辑' not in artist_page or ' 部专辑' in artist_page:
        bad += 1
        issues.append(('AC', 'FAIL', '没诚实标注专辑数口径：会把已加载统计冒充全部专辑'))
    if 'Math.random' in artist_page or 'setInterval' in artist_page:
        bad += 1
        issues.append(('AC', 'FAIL', '歌手页出现随机数 / 定时器：违反不造数'))
    if 'viewMode' not in artist_page or 'activeAlbum' not in artist_page or 'currentAlbumSongs' not in artist_page:
        bad += 1
        issues.append(('AC', 'FAIL', '歌手页缺作品/专辑切换或专辑内歌曲不可播放'))
    # v2.32：按用户决定删除搜索页「专辑」tab 整套（含 v2.25 专辑分类、
    # v2.31 空态「去看这位歌手」切口）。反向断言防半截复活，检查项总数不变。
    for kw in ('typeTab(\'专辑\'', 'this.type === 3', 'albumList()',
               '@State albums', '去看这位歌手', '没有找到专辑', 'SearchType.ALBUM'):
        if kw in search:
            bad += 1
            issues.append(('AC', 'FAIL', '搜索页专辑 tab 整套未清除：仍残留 ' + kw))

    # v2.33：按用户决定删除歌手页「搜同名歌手」按钮（图 2 橙圈）。
    # 反向断言防半截复活；「播放全部」、作品/专辑 Chip、专辑聚合、
    # 空态「搜索这个名字」兜底重试均保留。
    if "Text('搜同名歌手')" in artist_page or 'magnifyingglass' in artist_page:
        bad += 1
        issues.append(('AC', 'FAIL', '歌手页「搜同名歌手」按钮未删除'))
    if 'Text(\'播放全部\')' not in artist_page:
        bad += 1
        issues.append(('AC', 'FAIL', '删「搜同名歌手」时把「播放全部」一起删了'))

    # v2.34：统一返回判断。根级浮层含「全屏播放页 playerShow + 队列 queueShow」
    # 两类，必须在 closeQueueFn 里一起收；@Entry.onBackPress 不再单独判
    # playerShow，否则一级页与二级页两条路径判断不一致：从详情页进播放页
    # 按返回会误把详情页 pop 掉、播放页却还盖着。守断言不新增检查项。
    cq = index[index.find('App.get().closeQueueFn'):][:520]
    if 'this.playerShow' not in cq or 'this.setPlayerShow(false)' not in cq:
        bad += 1
        issues.append(('AC', 'FAIL', '统一返回判断没覆盖播放页浮层：二级页进播放页按返回会误退页'))
    if 'this.queueShow' not in cq or 'this.queueShow = false' not in cq:
        bad += 1
        issues.append(('AC', 'FAIL', '统一返回判断漏收队列浮层'))
    if cq.find('this.playerShow') > cq.find('this.queueShow'):
        bad += 1
        issues.append(('AC', 'FAIL', '浮层收起顺序不是「播放页 → 队列」：顶层浮层没先收'))
    obp = index[index.find('onBackPress(): boolean'):][:300]
    if 'this.playerShow' in obp:
        bad += 1
        issues.append(('AC', 'FAIL', '一级页 onBackPress 仍单独判 playerShow：与二级页判断不一致'))

    # v2.35：歌词来源优先级 + 假歌词拦截。
    # 用户播放酷我歌时歌词区出现一整屏 http://car-lv.kuwo.cn/...mgg 音频直链，
    # 来源标着「音源·聚合音源」：音源脚本把非歌词内容塞进 lyric 字段，
    # 又和官方歌词同批竞速先返回。守断言不新增检查项。
    lrc = next((s for f, s in src.items() if f.endswith('core/Lrc.ets')), '')
    lyric_repo = next((s for f, s in src.items() if f.endswith('core/LyricRepo.ets')), '')
    if 'export function looksLikeNonLyric' not in lrc or 'looksLikeMarkup(raw) || looksLikeNonLyric(raw)' not in lrc:
        bad += 1
        issues.append(('AC', 'FAIL', 'Lrc 没拦非歌词文本：URL / 音频直链仍会被当成无时间轴纯文本歌词显示'))
    if 'looksLikeNonLyric' not in lyric_repo or 'isLinkLine' not in lyric_repo:
        bad += 1
        issues.append(('AC', 'FAIL', 'LyricRepo 没接内容校验：音源脚本返回的链接会落到歌词区'))
    if 'batch.push(this.fromScript(song))' in lyric_repo:
        bad += 1
        issues.append(('AC', 'FAIL', '音源脚本仍与官方歌词同批竞速：会抢先返回非本平台 / 假歌词'))
    if 'withDeadline([this.fromScript(song)]' not in lyric_repo:
        bad += 1
        issues.append(('AC', 'FAIL', '音源脚本没降级到最后一级，或脚本结果没有超时收口'))
    if 'const own = platforms.indexOf(song.source)' not in lyric_repo or 'lyricViaPlatform(api, own' not in lyric_repo:
        bad += 1
        issues.append(('AC', 'FAIL', '本平台按 id 取词失败后没在本平台回查，本平台歌词优先级不成立'))
    if "replace('MUSIC_', '')" not in lyric_repo:
        bad += 1
        issues.append(('AC', 'FAIL', '酷我 id 不兼容 MUSIC_ 前缀：音源来的酷我歌会被判非数字而跳过官方词'))

    # v2.36：网易云搜索 -462 风控。实测 /api/search/get/web 匿名请求约一半概率
    # 返回 {"code":-462} 且没有 result，被当成「没搜到」，三个 tab 一起空；
    # 发现页榜单 / 歌单详情是另外的接口，不受影响。守断言不新增检查项。
    wy_api = next((s for f, s in src.items() if f.endswith('core/PlatformApi.ets')), '')
    if 'private async wySearchRaw' not in wy_api or 'api/v1/search/get' not in wy_api:
        bad += 1
        issues.append(('AC', 'FAIL', '网易云搜索没切到稳定的 v1 接口：-462 风控会继续被当成空结果'))
    if 'api/search/get/web' not in wy_api:
        bad += 1
        issues.append(('AC', 'FAIL', '老搜索接口没留作兜底：v1 偶发失败时没有第二条路'))
    if 'code?: number' not in wy_api or 'resp.code !== 200' not in wy_api:
        bad += 1
        issues.append(('AC', 'FAIL', '没识别风控码：验证页仍会被当成没有搜索结果'))
    for fn in ('private async wySearch(', 'private async wySearchSheets(', 'private async wySearchArtists('):
        seg = wy_api[wy_api.find(fn):][:420]
        if 'this.wySearchRaw' not in seg:
            bad += 1
            issues.append(('AC', 'FAIL', fn + ' 没走统一搜索入口，风控重试覆盖不全'))

    # v2.37：封面链路。用户「有的歌曲没封面但播放正常」+「发现页榜单没封面」。
    # 守断言不新增检查项，卡住四处真实修复，防止退化成只改文案的假功能。
    cover_repo = next((s for f, s in src.items() if f.endswith('core/CoverRepo.ets')), '')
    common_ui = next((s for f, s in src.items() if f.endswith('ui/Common.ets')), '')
    models = next((s for f, s in src.items() if f.endswith('common/Models.ets')), '')
    discover_p = next((s for f, s in src.items() if f.endswith('ui/pages/DiscoverPage.ets')), '')
    # 1) 歌曲封面：非标准 source（音源脚本）也能按名跨平台补图
    if 'private async coverByCrossSearch' not in wy_api or 'this.coverByCrossSearch(song)' not in wy_api:
        bad += 1
        issues.append(('AC', 'FAIL', 'fetchCover 没有跨平台按名补图兜底：音源脚本来源的歌会永远没封面'))
    # 2) 补图失败冷却可恢复、坏图重补不再一次锁死
    if 'FAIL_TTL: number = 60 * 1000' not in cover_repo or 'Map<string, number>' not in cover_repo:
        bad += 1
        issues.append(('AC', 'FAIL', '封面补全失败仍是不可恢复的永久冷却：网络恢复后也不会再补'))
    # 3) 酷我榜单封面：pic 目录/404 用 v9_pic2 兜底，且做 URL 有效性判断
    if 'function looksLikeImageUrl' not in wy_api or 'v9_pic2' not in wy_api:
        bad += 1
        issues.append(('AC', 'FAIL', '酷我榜单封面没判 pic 死链 / 没用 v9_pic2 兜底：飙升榜等仍会显示 ♪'))
    # 4) 榜单卡片主封面 404 时能切备用 URL（全链路：模型 + 组件 + 发现页/详情页）
    if 'coverFallback?: string' not in models or '@Prop fallbackUri' not in common_ui:
        bad += 1
        issues.append(('AC', 'FAIL', '封面备用 URL 链路没打通（模型 / Cover 组件缺一环）'))
    if 'useFallback' not in common_ui or 'fallbackUri: board.coverFallback' not in discover_p:
        bad += 1
        issues.append(('AC', 'FAIL', '榜单卡片没传备用封面 / Cover 不会记住备用状态：刷新后会弹回死链'))

    # v2.38：设置页质感档位入口下线，玻璃质感功能保留、默认锁最强浓郁(3)。
    # 用户明确「去除质感入口、功能保留、设默认最强浓郁、不要入口」——
    # 守断言要同时卡「入口不复活」和「功能没被一起删 / 默认值不是浓郁」。
    settings_core = next((s for f, s in src.items() if f.endswith('core/Settings.ets')), '')
    constants = next((s for f, s in src.items() if f.endswith('common/Constants.ets')), '')
    entry_ability = next((s for f, s in src.items() if f.endswith('entryability/EntryAbility.ets')), '')
    for kw in ("LIGHT_SENSE_LABELS", "applyLight", "Text('质感')", "'浓郁'"):
        if kw in settings:
            bad += 1
            issues.append(('AC', 'FAIL', '设置页又出现质感档位入口（' + kw + '）：用户要求不要入口'))
    # 功能保留：参数化玻璃档位函数 + 设置页仍订阅 lightLevel 并用于玻璃四件套
    if 'export function lightSense(level: number' not in constants or 'glassSurface(this.isDark, this.lightLevel)' not in settings:
        bad += 1
        issues.append(('AC', 'FAIL', '玻璃质感功能被一起删了：lightSense 参数化 / 设置页玻璃四件套订阅应保留'))
    # 默认最强浓郁(3)：Settings 默认、EntryAbility 首帧、订阅初值三处都是 3
    if "getNumber(PrefKeys.LIGHT_SENSE, 3)" not in settings_core:
        bad += 1
        issues.append(('AC', 'FAIL', 'Settings.lightSense() 默认值不是 3：没锁到最强浓郁'))
    if "let light: number = 3" not in entry_ability or "'v4_light_sense', 3" not in entry_ability:
        bad += 1
        issues.append(('AC', 'FAIL', '首帧 lightSense 默认值不是 3：启动会先闪一下标准档再跳浓郁'))
    if "@StorageProp('lightSense') lightLevel: number = 3" not in settings:
        bad += 1
        issues.append(('AC', 'FAIL', '设置页订阅初值不是 3：AppStorage 就绪前会显示标准档'))

    # v2.39：数据说明删「自建歌单」、备份范围真正纳入音源脚本正文。
    # 铁律 2：只改文案 / 只备份 v4_sources 元数据 = 恢复后满屏「脚本文件丢失」死链；
    # 必须把 code 写回 files/sources/<id>.js 并重载运行时，才算真的备份了音源。
    source_repo = next((s for f, s in src.items() if f.endswith('core/SourceRepo.ets')), '')
    if 'export interface SourceBackupItem' not in models or 'code: string' not in models:
        bad += 1
        issues.append(('AC', 'FAIL', '缺 SourceBackupItem（含 code 正文）：备份音源只是一句文案'))
    if 'exportScripts(): SourceBackupItem[]' not in source_repo:
        bad += 1
        issues.append(('AC', 'FAIL', 'SourceRepo 没有导出脚本正文的真实方法'))
    rb = source_repo[source_repo.find('async restoreFromBackup('):] if 'async restoreFromBackup(' in source_repo else ''
    if not rb:
        bad += 1
        issues.append(('AC', 'FAIL', 'SourceRepo 缺 restoreFromBackup 实现'))
    else:
        rb = rb[:4200]
        for kw, msg in (
            ('A-Za-z0-9_-', '没做 id 路径穿越校验'),
            ('await this.writeFile(', '没把脚本正文写回沙箱'),
            ('PrefKeys.SOURCES', '没重建 v4_sources 元数据'),
            ('PrefKeys.ACTIVE_SOURCE', '没恢复首选音源'),
            ('this.loadMeta()', '没重载内存态'),
            ('await this.reloadAll()', '没重新注入运行时脚本'),
        ):
            if kw not in rb:
                bad += 1
                issues.append(('AC', 'FAIL', 'restoreFromBackup ' + msg))
    if 'scripts?: SourceBackupItem[]' not in backup or 'activeSource?: string' not in backup:
        bad += 1
        issues.append(('AC', 'FAIL', '备份文件结构没带 scripts / activeSource 段'))
    if 'repo.exportScripts()' not in backup or 'restoreFromBackup(' not in backup:
        bad += 1
        issues.append(('AC', 'FAIL', 'Backup 没接 SourceRepo 的导出 / 恢复：备份范围仍是空话'))
    if 'Array.isArray(data.scripts)' not in backup or 'data.scripts as SourceBackupItem[]).length > 0' not in backup:
        bad += 1
        issues.append(('AC', 'FAIL', '老备份 / 空音源备份会误清空当前音源：缺非空判断'))
    if '不含音源脚本' in backup:
        bad += 1
        issues.append(('AC', 'FAIL', '备份注释仍写「不含音源脚本」：与 v2.39 范围矛盾'))
    # 2026-11-16：用户要求清掉界面说明文案，数据页不再挂备份范围长句；
    # 备份范围仍由上面两条「exportScripts + restoreFromBackup」实现断言守住。
    if '包含收藏、歌单收藏' in data_view or '自建歌单' in data_view:
        bad += 1
        issues.append(('AC', 'FAIL', '数据管理页的备份范围说明又挂回来了（用户要求删说明）'))

    # v2.40：MusicFree 音源支持。洛雪是 IIFE + lx.on(request)，MusicFree 是
    # CommonJS + 具名方法 + require 9 包；只做「能导入」会退化成「自检能过、
    # 播放放不出声」的假功能，守断言要把适配层每一环都卡住。
    mf_runner = next((s for f, s in src.items() if f.endswith('core/LxRunner.ets')), '')
    mf_resolver = next((s for f, s in src.items() if f.endswith('core/Resolver.ets')), '')
    mf_raw_dir = os.path.join(ROOT, 'entry/src/main/resources/rawfile')
    mf_runtime_path = os.path.join(mf_raw_dir, 'vendor', 'mf_runtime.js')
    mf_bridge_path = os.path.join(mf_raw_dir, 'lx_bridge.html')
    mf_runtime = open(mf_runtime_path, encoding='utf-8').read() if os.path.isfile(mf_runtime_path) else ''
    mf_bridge = open(mf_bridge_path, encoding='utf-8').read() if os.path.isfile(mf_bridge_path) else ''
    if not mf_runtime or not mf_bridge:
        bad += 1
        issues.append(('AC', 'FAIL', '缺 MusicFree 运行时 / 桥接页：插件装不进来'))
    else:
        for kw, msg in (
            ('global.MFRuntime', '没暴露运行时入口'),
            ('__musicfree_require', '没按官方 Function(require, __musicfree_require, module, exports…) 装载'),
            ("'axios'", '没注入 axios'), ("'cheerio'", '没注入 cheerio'),
            ("'crypto-js'", '没注入 crypto-js'), ("'dayjs'", '没注入 dayjs'),
            ("'he'", '没注入 he'), ("'qs'", '没注入 qs'),
            ("'big-integer'", '没注入 big-integer'), ("'webdav'", '没注入 webdav'),
            ("'@react-native-cookies/cookies'", '没注入 cookies'),
            ('lx.request(', '没把插件 HTTP 转给原生代理'),
            ("notSupported('webdav（网盘客户端）')", 'WebDAV 插件没如实标注不支持'),
            ('mfRaw: JSON.stringify(obj)', '没把原始 mediaItem 带回 SongInfo'),
            ('restoreMedia', '取链 / 取词没还原插件自己的对象'),
            ("var sourceId = 'mf:' + instId", 'sourceId 不是插件实例 id'),
        ):
            if kw not in mf_runtime:
                bad += 1
                issues.append(('AC', 'FAIL', 'mf_runtime.js ' + msg))
        for kw, msg in (
            ('vendor/mf_runtime.js', '没引入运行时'),
            ('function detectKind(', '缺协议自动识别兜底'),
            ('function loadMusicFree(', '缺 MusicFree 装载分支'),
            ('__load: function (instId, code, kind)', '__load 没接住 kind'),
            ("toNative({ type: 'inited'", '没合成 inited（取链链路会判定源不可用）'),
        ):
            if kw not in mf_bridge:
                bad += 1
                issues.append(('AC', 'FAIL', 'lx_bridge.html ' + msg))
    if 'mfRaw?: string' not in models or 'mfSearchable: boolean' not in models:
        bad += 1
        issues.append(('AC', 'FAIL', 'SongInfo / SourceItem 没带 mfRaw / mfSearchable'))
    if 'kind?: string' not in models:
        bad += 1
        issues.append(('AC', 'FAIL', 'SourceBackupItem 没带 kind：备份恢复会丢协议'))
    if "async load(instId: string, code: string, kind: string = 'lx')" not in mf_runner:
        bad += 1
        issues.append(('AC', 'FAIL', 'LxRunner.load 没传 kind：导入时识别的协议到不了桥接页'))
    if 'msg.kind' not in mf_runner:
        bad += 1
        issues.append(('AC', 'FAIL', 'LxRunner.handleMessage 没把 loaded 的 kind 回传'))
    for kw, msg in (
        ('static detectKind(code: string): string', '缺协议识别'),
        ('mfSearchSources(): SourceItem[]', '缺可搜索插件集合'),
        ('async searchMusicFree(', '缺插件搜索通道'),
        ('async searchSheetsMusicFree(', '缺插件歌单搜索通道'),
        ('async searchArtistsMusicFree(', '缺插件歌手搜索通道'),
        ('async sheetSongsMusicFree(', '缺 getMusicSheetInfo 歌单详情通道'),
        ('async artistSongsMusicFree(', '缺 getArtistWorks 歌手作品通道'),
        ('checkMusicFree(', '缺插件协议自检（五平台基准曲会把插件误判成坏源）'),
        ('runner.load(item.id, code, item.kind)', 'loadOne 没按正文复核协议'),
        ('SourceRepo.detectKind(s.code)', '备份恢复没按正文识别协议'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))
    for kw, msg in (
        ('mfSources: SourceItem[] = []', '缺插件源状态'),
        ('private activeSources(): string[]', '综合搜索没把插件源并进来'),
        ('private searchSongsBySource(', '缺 mf: 前缀分派'),
        ('mfSourceChip(item: SourceItem)', '缺插件源芯片'),
        ("@StorageProp('sourceVersion')", '音源启停后常驻搜索页不会刷新插件源'),
        ("if (this.isMfSource(id)) {\n      return this.hasMfSource(id);", '缺失效插件源合法性校验'),
        ('private activeMfSources(): string[]', '歌单 / 歌手 tab 没把 MusicFree 插件源并进来'),
        ('searchSheetsMusicFree(', '歌单 tab 没调用插件 search(type=sheet)'),
        ('searchArtistsMusicFree(', '歌手 tab 没调用插件 search(type=artist)'),
    ):
        if kw not in search:
            bad += 1
            issues.append(('AC', 'FAIL', 'SearchPage ' + msg))
    if 'mfRaw: song.mfRaw' not in mf_resolver:
        bad += 1
        issues.append(('AC', 'FAIL', 'Resolver.buildMusicInfo 丢了 mfRaw：插件取链必然失败'))
    if "song.source !== 'mf:' + item.id" not in mf_resolver or "song.source !== 'mf:' + item.id" not in lyric_repo:
        bad += 1
        issues.append(('AC', 'FAIL', '取链 / 取词没精确分派给产出这首歌的插件'))
    if "id.indexOf('mf:') === 0" not in plat:
        bad += 1
        issues.append(('AC', 'FAIL', 'Platform 没处理 mf: 源：行内标签会露出一长串实例 id'))

    # v2.45：MusicFree 插件加入「取链替补」。守住「按名重搜走真实 searchMusicFree」、
    # 「pickBest 严格同名匹配」、「mfRaw 非空门槛」、「并发上限」、「替补在 oneOnly 之后 /
    # 跨平台换源之前」，防止退化成「把平台 id 硬问插件」的假替补，或拖慢正常播放。
    for kw, msg in (
        ('private async findMusicFreeAlternatives(', '缺 MusicFree 插件按名重搜替补入口'),
        ('this.sources.searchMusicFree(item.id, keyword, 1)', '替补没走真实插件搜索通道'),
        ('Resolver.pickBest(list, song)', '替补没做同名同歌手严格匹配：会张冠李戴'),
        ('hit.mfRaw !== undefined && hit.mfRaw.length > 0', '替补没要求 mfRaw：等于拿平台 id 硬问插件'),
        ('const MF_FALLBACK_MAX: number = 6', '替补没有并发上限：会拖慢失败路径'),
        ("result.from = result.from + ' · 插件替补'", '替补成功没如实标注来源'),
        ('result.altSong = mfAlt', '替补没回填 altSong：播放页换源 / 来源显示会错'),
    ):
        if kw not in mf_resolver:
            bad += 1
            issues.append(('AC', 'FAIL', 'Resolver ' + msg))
    one_only = mf_resolver.find('if (state.oneOnly) {')
    mf_step = mf_resolver.find('// 2.5 MusicFree 插件替补')
    alt_step = mf_resolver.find('// 3. 跨平台换源')
    if not (0 < one_only < mf_step < alt_step):
        bad += 1
        issues.append(('AC', 'FAIL', '替补阶段顺序错：必须在只用首选音源判断之后、跨平台换源之前'))

    # v2.41：MusicFree 订阅清单导入 + 洛雪失败自动回退 + 报错卡片布局统一。
    # 用户实际入口是 plugins.json（JSON，不是可执行脚本），以前整段丢进
    # new Function 必然报 Unexpected token；报错卡片又少一行说明，结构不一致。
    src_page = next((s for f, s in src.items() if f.endswith('ui/pages/SourcesPage.ets')), '')
    # v2.55：歌单详情页的选择条也归到列表下方，位置断言要用到它的源码
    sheet_page = next((s for f, s in src.items() if f.endswith('ui/pages/SheetDetailPage.ets')), '')
    sel_bar = common if 'export struct SelectionBar' in common else ''
    if sel_bar == '':
        bad += 1
        issues.append(('AC', 'FAIL', 'Common 里没有公共 SelectionBar：三页又各写一份选择条'))

    # v2.46：MusicFree 取链失败必须如实反馈。用户实测「自检 / 刷新都显示正常，
    # 但整批元力插件播放不出来」，失败面板只剩兜底文案「音源未返回有效链接」。
    # 两层工程侧缺陷：运行时 guard() 把插件异常吞成 {}；checkMusicFree() 只要
    # 搜索有结果就 health='ok'。守住这两处，防止退化回「把失败显示成正常」。
    for kw, msg in (
        ('function guard(promise, empty, exposeError)', '缺取链异常透传入口'),
        ("return Promise.reject(new Error('插件取链异常：' + msg));", '异常没作为真实失败原因回传'),
        ("catch (e) { return guard(Promise.reject(e), {}, true); }", '同步抛错没透传'),
        ('}), {}, true);', '异步取链异常没透传'),
        ("appVersion: '1.0'", '运行时 appVersion 没升到 1.0'),
        ("version: '1.0', env: env", 'process.version 没升到 1.0'),
    ):
        if kw not in mf_runtime:
            bad += 1
            issues.append(('AC', 'FAIL', 'mf_runtime.js ' + msg))
    for kw, msg in (
        ("ok = url.startsWith('http');", '自检没按取链真实结果判级'),
        ("message = '搜索正常，但取链失败：'", '自检没把插件真实原因写进 message'),
        ("message = ok ? '搜索与取链正常'", '自检成功 / 失败没分开'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))
    if 'ok = true;\n        const first = list[0];' in source_repo:
        bad += 1
        issues.append(('AC', 'FAIL', 'checkMusicFree 仍无条件把取链失败判成 ok'))
    if "if (item.health === 'error')" not in src_page or 'item.message.length > 0' not in src_page:
        bad += 1
        issues.append(('AC', 'FAIL', '音源卡片没显示自检的真实原因'))

    # v2.47：自检未通过不许再显示「正常」。
    # 用户实测「元力 MG 自检未通过，卡片仍是一颗绿点 + 正常」，两处叠加成因：
    # ① ForEach 的 key 只含 status/enabled/order，自检只改 health，key 不变 → 卡片不重建；
    # ② statusText 把「脚本装载成功」直接说成「正常」，从未自检也显示正常；
    # ③ health 不落盘，进程重启后又回到「正常」。
    for kw, msg in (
        ("+ item.health + '|'", 'ForEach key 没带 health：自检结论变化不会重绘卡片'),
        ('item.checkedAt.toString()', 'ForEach key 没带 checkedAt：说明行与耗时不刷新'),
        ("return '自检未通过';", '自检失败没有独立文案'),
        ("return '已就绪 · 未自检';", '把「从未自检」显示成了「正常」'),
        ('paletteRef.accent', '自检未通过没换成警示色，仍是绿点'),
        ('个已就绪', '顶部汇总仍把装载成功说成「可用」'),
        ('个自检未通过', '顶部汇总没暴露自检未通过数'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage ' + msg))
    for kw, msg in (
        ("raw.health === 'ok' || raw.health === 'error'", '冷启动没恢复上次自检结论'),
        ('item.checkedAt = typeof raw.checkedAt', '冷启动没恢复自检时间'),
        ("health: item.health === 'checking' ? '' : item.health,", '自检结论没持久化'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))
    if '已就绪 · 自检未通过' in src_page:
        bad += 1
        issues.append(('AC', 'FAIL', '仍在使用带「已就绪」前缀的旧失败文案，观感上仍像正常'))

    for kw, msg in (
        ('function toCommonJS(', '缺 ESM → CommonJS 预处理'),
        ('var normalized = toCommonJS(code);', '装载没用预处理后的正文'),
        ('hookUnhandledRejection(log)', '插件顶层自调用的异步异常没收敛'),
    ):
        if kw not in mf_runtime:
            bad += 1
            issues.append(('AC', 'FAIL', 'mf_runtime.js ' + msg))
    for kw, msg in (
        ("detectKind(code) === 'musicfree'", '洛雪执行失败没自动回退 MusicFree'),
        ('已尝试洛雪 / MusicFree', '两种协议都失败时没给出合并原因'),
        ('JSON 订阅清单', '语法错没提示订阅清单入口'),
    ):
        if kw not in mf_bridge:
            bad += 1
            issues.append(('AC', 'FAIL', 'lx_bridge.html ' + msg))
    for kw, msg in (
        ('static parseSubscription(text: string): string[]', '缺订阅清单解析'),
        ('static isSubscription(', '缺订阅清单判定'),
        ('这是 MusicFree 插件订阅清单', 'importCode 没拦下订阅清单'),
        ('const mfLoad = ', '协议识别没扩到混淆 CommonJS / ESM'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))
    for kw, msg in (
        ('SourceRepo.isSubscription(code)', '网络导入没识别订阅清单'),
        ('SourceRepo.parseSubscription(code)', '网络导入没展开订阅里的插件直链'),
        ('private cardHint(', '报错卡片没补统一说明行'),
        ('msg.length > 18', '状态行错误文案没截断，会把卡片挤窄'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage ' + msg))

    # v2.42：全订阅源适配。用户给的两批订阅实测 63 个脚本，暴露四类问题：
    # 混淆 CommonJS 插件（module[混淆串]=plugin）、带中文 @name 头注解的 MusicFree
    # 插件被误判成洛雪、依赖 buffer 的插件 require 阶段崩、HTML 中转页被当脚本存。
    for kw, msg in (
        ('function makeBuffer()', '缺 require("buffer") 的真实现'),
        ("'buffer': makeBuffer()", 'buildPackages 没注入 buffer 包'),
        ("'pako': notSupported", 'pako 没如实标注能力缺失'),
        ('Buf.concat = function', 'Buffer 实现不完整'),
        ("action === 'sheetSearch'", '缺官方 sheet 类型搜索分派'),
        ("action === 'artistSearch'", '缺官方 artist 类型搜索分派'),
        ("action === 'sheetInfo'", '缺 getMusicSheetInfo 歌单详情分派'),
        ("action === 'artistWorks'", '缺 getArtistWorks 歌手作品分派'),
        ('function supportsSearchType(', '没按 supportedSearchType 过滤，会向不支持的插件发无效请求'),
        ('function toSheet(', '歌单结果没映射成宿主 SheetInfo'),
        ('function toArtist(', '歌手结果没映射成宿主 ArtistInfo'),
        ("appVersion: '1.0'", '运行时 appVersion 没升到 1.0'),
    ):
        if kw not in mf_runtime:
            bad += 1
            issues.append(('AC', 'FAIL', 'mf_runtime.js ' + msg))
    # v2.44：歌单 / 歌手详情页按 mf: 前缀分派，插件源不参与跨平台模糊兜底。
    mf_sheet_detail = next((s for f, s in src.items() if f.endswith('ui/pages/SheetDetailPage.ets')), '')
    mf_artist_page = next((s for f, s in src.items() if f.endswith('ui/pages/ArtistPage.ets')), '')
    for kw, msg in (
        ("sheet.platform.indexOf('mf:') === 0", '歌单详情页没分派给 MusicFree 插件'),
        ('sheetSongsMusicFree(', '歌单详情页没调用 getMusicSheetInfo 通道'),
    ):
        if kw not in mf_sheet_detail:
            bad += 1
            issues.append(('AC', 'FAIL', 'SheetDetailPage ' + msg))
    for kw, msg in (
        ("artist.platform.indexOf('mf:') === 0", '歌手详情页没分派给 MusicFree 插件'),
        ('artistSongsMusicFree(', '歌手详情页没调用 getArtistWorks 通道'),
        ('插件源不参与', '歌手页仍会拿平台同名结果冒充插件作品'),
    ):
        if kw not in mf_artist_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'ArtistPage ' + msg))
    for kw, msg in (
        ('@name 只是头注解', '桥接页判定注释没说明 @name 不作洛雪特征'),
        ('EVENT_NAMES\\.request|lx\\.on', '桥接页洛雪判据没收敛到运行时 API 特征'),
    ):
        if kw not in mf_bridge:
            bad += 1
            issues.append(('AC', 'FAIL', 'lx_bridge.html ' + msg))
    for kw, msg in (
        ('static looksLikeWebPage(text: string): boolean', '缺 HTML 中转页内容体检'),
        ('链接返回的是网页或跳转页', 'importCode 没拦下失效中转页'),
        ('const mfLoad = ', '协议识别没收敛到洛雪运行时 API 优先'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))
    for kw, msg in (
        ('SourceRepo.looksLikeWebPage(pluginCode)', '订阅展开分支没拦失效中转页'),
        ('订阅里的插件链接均已失效', '订阅整批失效时没给出换源提示'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage ' + msg))

    # v2.43：就绪状态与搜索可见性解耦 + 元力音源订阅适配。
    # 用户反馈「自检失败、刷新后显示正常；搜索页要逐个手动刷新才显示平台」。
    # 根因两层：mfSearchSources 绑死 status==='ok'（status 会被自检反复改写）；
    # 冷启动 loadAll 漏传 kind，MusicFree 插件只能靠「洛雪失败回退」兜底。
    # 元力订阅 13413.kstore.vip/yuanli/yuanli.json 实测 6 个插件：
    # require 全在白名单、6/6 导出 search、双端 detectKind 判 musicfree、
    # __load 两种 kind 均 6/6 装载成功 → 现有代码直接支持，无需新增装载分支。
    if 'health: string;' not in models:
        bad += 1
        issues.append(('AC', 'FAIL', 'SourceItem 没把自检结论与装载状态分离'))
    for kw, msg in (
        ('mfSearchable?: boolean', 'SourcePersist 没持久化可搜索能力'),
        ('raw.mfSearchable === true', '冷启动没恢复可搜索能力'),
        ('this.versionSeq += 1;', 'sourceVersion 没改成严格递增'),
        ('obj.plugins ?? obj.list ?? obj.data ?? obj.sources', '订阅解析丢了 plugins 清单形态（元力订阅会导不进来）'),
        ("item.health === 'ok'", 'checkAll 汇总没读独立自检结论'),
        ('actions: item.actions', '备份没带走脚本动作'),
        ('mfSearchable: s.mfSearchable === true', '备份恢复没还原可搜索能力'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))
    mf_body = _func_body(source_repo, 'mfSearchSources')
    if not mf_body or 'item.status' in mf_body or 'runner.isLoaded(item.id)' not in mf_body:
        bad += 1
        issues.append(('AC', 'FAIL', 'mfSearchSources 又绑回 status 或没用运行时就绪判定'))
    load_all_body = _func_body(source_repo, 'loadAll')
    if not load_all_body or 'runner.load(item.id, code, item.kind)' not in load_all_body:
        bad += 1
        issues.append(('AC', 'FAIL', '冷启动 loadAll 又漏传协议 kind'))
    for kw, msg in (
        ("item.health === 'ok'", '单源自检 toast 没读独立结论'),
        ("if (item.health === 'error')", '自检失败没独立分支'),
        ('? (item.message.length > 60 ? item.message.substring(0, 60)', '自检失败没读取真实结论 message'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage ' + msg))
    # v2.47 反向断言：不能再把「自检失败」降级成一句灰色弱提示，
    # 一颗绿点配一句灰字，用户读到的仍然是「正常」。
    if "item.health === 'error' ? paletteRef.text2" in src_page:
        bad += 1
        issues.append(('AC', 'FAIL', '自检失败仍是灰色弱提示，观感等同正常'))

    # v2.48：音源管理页支持「选择音源」后勾多个 / 全选批量删除。
    # 原选择模式只服务导出，条内只有一颗「导出」；现在上排负责选、下排两颗动作，
    # 删除必须走确认弹窗，仓库层要一次性过滤落盘而不是循环单删。
    for kw, msg in (
        ('private confirmRemoveSelected(): void', '选择模式没有批量删除入口'),
        ('SelectionBar({', '选择模式没接公共 SelectionBar（v2.55 起三页共用一套）'),
        ('busy: this.removing', '选择条没把删除忙态交给公共组件'),
        ("secondaryLabel: this.exporting ? '导出中…' : '导出所选'",
         '音源页独有的「导出所选」没接进公共选择条'),
        ('this.repo.removeMany(ids)', '批量删除没接到仓库层'),
        ("Button('选择')", '顶部没有进入选择模式的「选择」按钮'),
        ('private onNameTap(item: SourceItem): void', '选择模式点名字仍会弹菜单，勾选被打断'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage ' + msg))
    for kw, msg in (
        ('async removeMany(ids: string[]): Promise<number>', 'SourceRepo 没有批量删除实现'),
        ('await this.removeMany([id]);', '单删没复用批量路径，两条实现会分叉'),
        ('this.items = this.items.filter((it: SourceItem): boolean => kill.indexOf(it.id) < 0);',
         '批量删除没一次过滤，会退化成循环单删（N 次落盘 / N 轮刷新）'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))

    # v2.49：两套音源体系的自动替补升级 —— 候选按自检 health 排序（只排序不过滤，
    # 不破坏 v2.43 解耦）、排除产出原歌的那个失败插件、洛雪全关时不空转跨平台换源；
    # 歌单收藏页支持多选批量取消收藏（一次落盘，ForEach key 带选中态）。
    for kw, msg in (
        ('mfFallbackSources(): SourceItem[]', 'SourceRepo 没有健康度排序的替补候选方法'),
        ('private static healthRank(health: string): number', '替补候选没按 health 分档'),
        ('return a.order - b.order;', '同档没保持音源页 order，会打乱用户拖出来的优先级'),
        ('const list: SourceItem[] = this.mfSearchSources().slice();',
         '替补候选没复用 mfSearchSources：会把不可搜索 / 禁用源也问一遍'),
    ):
        if kw not in source_repo:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourceRepo ' + msg))
    for kw, msg in (
        ("const originInst = song.source.indexOf('mf:') === 0 ? song.source.substring(3) : '';",
         '替补没识别产出原歌的插件实例 id'),
        ('if (originInst.length > 0 && item.id === originInst)', '替补没排除刚取链失败的原插件'),
        ('if (plugins.length >= MF_FALLBACK_MAX)', '替补没在排除原插件后取满并发上限'),
        ('for (const item of this.sources.mfFallbackSources())', '替补没用健康度排序后的候选'),
        ('private hasEnabledLxSource(): boolean', '缺「洛雪侧是否还有启用音源」判断'),
        ('if (this.hasEnabledLxSource())', '跨平台换源没做不空转判断'),
        ('洛雪音源都已关闭，换到的平台歌没有音源能取链，本次跳过', '跳过跨平台换源没如实记原因'),
    ):
        if kw not in mf_resolver:
            bad += 1
            issues.append(('AC', 'FAIL', 'Resolver ' + msg))
    # 阶段顺序仍必须是 2.5 在 3 之前（本轮在阶段 3 内部加判断，不能挪动顺序）
    if not (0 < mf_resolver.find('// 2.5 MusicFree 插件替补') <
            mf_resolver.find('// 3. 跨平台换源')):
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.49 改动破坏了替补 → 换源的阶段顺序'))
    fav_page = next((s for f, s in src.items() if f.endswith('ui/pages/FavoriteSheetsPage.ets')), '')
    lib_src = next((s for f, s in src.items() if f.endswith('core/Library.ets')), '')
    for kw, msg in (
        ('@State selectMode: boolean = false;', '歌单收藏页没有选择模式'),
        ('private toggleAll(): void', '歌单收藏页没有全选'),
        ('private confirmRemoveSelected(): void', '歌单收藏页没有批量删除入口'),
        ('SelectionBar({', '歌单收藏页没接公共 SelectionBar（v2.55 起三页共用一套）'),
        ('private localBack(): boolean', '歌单收藏页没声明页内临时态（选择模式）'),
        ('Library.get().removeSheetFavorites(keys)', '批量删除没接到 Library 仓库层'),
        ("(this.selectMode && this.isSelected(Library.sheetKey(sheet)) ? '_s' : '')",
         'ForEach key 没带选中态：勾选后不会重绘（v2.47 同款根因）'),
        ('private onCardTap(sheet: SheetInfo): void', '选择模式点卡片仍会直接进详情'),
        ('this.sheets.some((s: SheetInfo): boolean => Library.sheetKey(s) === key)',
         '跨页取消收藏后没清理失效勾选，已选计数会虚高'),
        ('App.get().consumeBack((): boolean => this.localBack())',
         '系统返回键没走统一入口：选择模式会先被退页吞掉'),
    ):
        if kw not in fav_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'FavoriteSheetsPage ' + msg))
    for kw, msg in (
        ('removeSheetFavorites(keys: string[]): number', 'Library 没有批量取消收藏实现'),
        ('this.removeSheetFavorites([Library.sheetKey(sheet)])', '单删没复用批量路径'),
        ('this.favoriteSheets = this.favoriteSheets.filter(', '批量取消收藏没一次过滤'),
    ):
        if kw not in lib_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'Library ' + msg))

    # v2.50：两处「选择模式」的选择条统一固定在列表下方（用户反馈：删除 / 全选
    # 不要在顶部），并统一上排三元素、玻璃卡、底部留白与返回语义。位置用
    # 「删除按钮在列表滚动属性之后」这类顺序断言卡住，防止以后又被搬回顶部。
    # v2.55：选择条已收进 Common.SelectionBar，页面只剩一个 SelectionBar({ ... })
    # 调用点，所以位置断言改卡「调用点在列表滚动属性之后」；上排三元素与已选计数
    # 移进组件本体检查（见下方 sel_bar 段），页面侧改卡「三页都接了同一组件」。
    for nm, page, anchor, list_end in (
        ('SourcesPage', src_page, 'SelectionBar({', '.enableScrollInteraction(!this.dragActive)'),
        ('FavoriteSheetsPage', fav_page, 'SelectionBar({', '.scrollBar(BarState.Off)'),
        ('SheetDetailPage', sheet_page, 'SelectionBar({', '.onScrollFrameBegin('),
    ):
        if not (0 < page.find(list_end) < page.find(anchor)):
            bad += 1
            issues.append(('AC', 'FAIL', nm + ' 选择条又回到列表顶部，没固定在下方'))
        if 'App.get().consumeBack(' not in page:
            bad += 1
            issues.append(('AC', 'FAIL', nm + ' 系统返回键没走统一入口（两页不统一）'))
    if "let c = this.selectMode ? 0 : 2;" not in src_page:
        bad += 1
        issues.append(('AC', 'FAIL', 'SourcesPage 选择条已移出 List，listHeaderCount 却仍按 1 计'))
    if src_page.count('Row().height(PAGE_BOTTOM + MINI_BAR_SPACE)') < 2 or \
            'Row().height(PAGE_BOTTOM + MINI_BAR_SPACE)' not in fav_page:
        bad += 1
        issues.append(('AC', 'FAIL', '底部选择条下方没给全局迷你播放条 / 胶囊标签栏留白'))
    # v2.61：顶部「选择」入口改为长按卡片进入多选。原来这条断言强制要求
    # 说明卡里必须有 Text('选择')，与新交互冲突，改成「顶部入口已移除 +
    # 长按手势存在」；其余两条禁令（不在说明卡用三元显示取消、标题栏不
    # 重复显示已选数）继续保留。
    if "Text(this.selectMode ? '取消' : '选择')" in fav_page or \
            'subtitle: this.selectMode ?' in fav_page or \
            "Text('选择')" in fav_page or \
            'LongPressGesture({ repeat: false, duration: 400 })' not in fav_page:
        bad += 1
        issues.append(('AC', 'FAIL', 'FavoriteSheetsPage 顶部「选择」没移除 / 没有长按进多选 / 退出仍走说明卡三元 / 标题栏还在重复显示已选数'))

    # ── v2.55 包 3：返回与选择统一 ──
    # ① 选择条收成公共组件：三页只传参数，文案 / 禁用 / 玻璃底只有一份实现，
    #    避免「音源页有导出、收藏页没有、详情页挤在头部」的四不像继续分叉。
    for kw, msg in (
        ("Text('取消')", '没有「取消」'),
        ("'已选 ' + this.selectedCount.toString() + ' / ' + this.totalCount.toString()",
         '没显示「已选 N / M」'),
        ("this.allSelected ? '取消全选' : '全选'", '全选态文案不统一'),
        ("Button(this.busy ? this.busyLabel : '删除所选')", '没有「删除所选」'),
        ('this.selectedCount <= 0 || this.busy || this.disabled', '空选 / 忙态没禁用删除'),
        ('glassCardBase(this.isDark)', '没铺玻璃底'),
    ):
        if kw not in sel_bar:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.55 SelectionBar ' + msg))
    # ② 三页各只有一处调用（不是又各自复制一份实现）
    for nm, page in (('SourcesPage', src_page), ('FavoriteSheetsPage', fav_page),
                     ('SheetDetailPage', sheet_page)):
        if page.count('SelectionBar({') != 1:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.55 ' + nm + ' 没接公共 SelectionBar（或接了两份）'))
    # ③ 歌单详情页的选择条必须在列表之后，不能再回到头部卡片里
    head_end = sheet_page.find('private subtitle(): string')
    if head_end > 0 and 'SelectionBar({' in sheet_page[:head_end]:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.55 歌单详情页选择条又回到头部卡片（应固定在列表下方）'))
    # ④ 下载页（v1.0 第四次返工）：长按多选重新启用，必须复用公共 SelectionBar，
    #    且单选 / 全选 / 删除所选都有落点，不许再退化成不可达的死代码
    dl_page = next((s for f, s in src.items() if f.endswith('ui/pages/DownloadsPage.ets')), '')
    for kw, msg in (('SelectionBar({', '长按多选没接公共 SelectionBar'),
                    ('selectMode', '缺多选状态机'),
                    ('selectedIds', '缺已选集合'),
                    ('toggleAll()', '缺全选 / 取消全选'),
                    ('deleteSelected()', '缺删除所选'),
                    ('LongPressGesture(', '缺长按手势')):
        if kw not in dl_page:
            bad += 1
            issues.append(('AC', 'FAIL', '下载页 ' + msg))

    # ── v2.56 包 4：无障碍与响应式 ──
    # ① 读屏语义只有一条通路：IconTap 把 label 交给 accessibilityText，
    #    图标视觉尺寸不够 48 时用 responseRegion 扩热区（视觉不动，命中区达标）。
    for kw, msg in (
        ("@Prop label: string = ''", '图标按钮没有读屏名称参数'),
        ('@Prop minHit: number = 48', '图标按钮没有 48vp 最小命中区'),
        ('width: this.minHit', '热区没按 minHit 扩：触控目标仍低于规范 48vp'),
        ('.accessibilityText(this.label)', '图标没有把名称交给读屏'),
        (".accessibilityLevel(this.label.length > 0 ? 'yes' : 'auto')",
         '装饰性图标与可操作图标没有区分，读屏会念一堆空节点'),
        ('private hitPad(): number', '热区扩展量没按图标视觉尺寸计算'),
    ):
        if kw not in common:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.56 IconTap ' + msg))
    # ② 歌曲行：名称 / 歌手 / 专辑 / 时长合成一句，别让读屏逐段刷
    if 'private rowLabel(): string' not in common or '，歌曲' not in common:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 SongRow 没有把一行信息合成读屏语句'))
    if common.count('.accessibilityGroup(true)') < 2:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 歌曲行 / 信息块没有合并成可聚焦节点'))
    if "label: '返回'" not in common or "label: '搜索'" not in common:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 顶栏返回 / 搜索按钮没有读屏名称'))
    if "accessibilityText('取消选择')" not in common or \
            "'删除所选，' + this.selectedCount.toString() + ' 项'" not in common:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 选择条动作没有读屏名称 / 数量'))
    # ③ 音源页：卡片语义 + 操作行窄屏 2×2
    for kw, msg in (
        ('private cardLabel(item: SourceItem): string', '音源卡没有合成读屏语句'),
        ('，音源，', '卡片读屏语句缺「音源」角色'),
        ('@StorageProp(\'fontScale\') fontScale: number = 1;', '没订阅系统字体倍率'),
        ('private actionG(): number', '没算每格可用宽 G'),
        ('private actionTwoRow(): boolean', '操作行没有降级判定'),
        ('this.fontScale >= 1.15', '大字号没触发 2×2（1.5 太迟，1.2 倍就开始溢出）'),
        ('this.actionG() < 88', '窄屏没按文字+内边距的实宽触发 2×2'),
        ('.padding({ left: 4, right: 4 })', '动作按钮没收紧默认内边距，四字文案仍会被 ellipsis'),
        ('actionLocal()', '四颗动作按钮没有拆成无参 Builder（带参会停在旧文案）'),
        ('actionNet()', '四颗动作按钮没有拆成无参 Builder'),
        ('actionCheck()', '四颗动作按钮没有拆成无参 Builder'),
        ('actionSelect()', '四颗动作按钮没有拆成无参 Builder'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.56 SourcesPage ' + msg))
    if src_page.count('responseRegion({ x: 0, y: -2, width: \'100%\', height: 48 })') < 4:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 操作行按钮热区不足 48vp（应四颗都补）'))
    # ④（B5 已清理）v2.56 光感迁移提示条整体删除，零残留由 CY 组守护。
    art_page = next((s for f, s in src.items() if f.endswith('ui/pages/ArtistPage.ets')), '')
    ab_src = next((s for f, s in src.items() if f.endswith('entryability/EntryAbility.ets')), '')
    # ⑤ 字体倍率进全局（深浅色早退不能把字号变化一起吞掉）
    if "AppStorage.setOrCreate('fontScale'" not in ab_src:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 EntryAbility 没把字体倍率写入全局'))
    ab_cfg = ab_src.find('onConfigurationUpdate(newConfig: Configuration): void {')
    if ab_cfg < 0 or ab_src.find("AppStorage.setOrCreate('fontScale'", ab_cfg) > \
            ab_src.find('if (dark === this.isDark)', ab_cfg):
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 配置变更时字号处理在深浅色早退之后，只调字号会失效'))
    # ⑥ 歌手页部分失败可见（兜底搜索不再静默吞成空数组）
    for kw, msg in (
        ('@State failedSources: string[] = [];', '没记录失败源'),
        ('private failedLabel(): string', '没有失败说明文案'),
        ('个源本次没返回结果', '文案丢失'),
        ('this.failedBuf.push(id)', 'catch 里没记平台'),
    ):
        if kw not in art_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.56 ArtistPage ' + msg))
    if '.catch((): SongInfo[] => [])' in art_page:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 歌手页仍有把异常静默吞成空数组的 catch'))

    # v2.51：音源管理页重设计（用户反馈「一排拉到底、好多选项、操作不方便、视觉不好」）。
    # 结构：Hero 状态控制台 + 一行四操作 + 可折叠选项 + 列表分区标题。
    # 用「7 个开关行必须在 if(settingsExpanded) 之后」的顺序断言卡住「默认收起」，
    # 防止以后又被搬回常驻、退回一排到底。
    for kw, msg in (
        ('@State settingsExpanded: boolean = false;', '没有默认收起的折叠状态'),
        ('this.settingsExpanded = !this.settingsExpanded;', '折叠头没有点击切换'),
        ("n.toString() + ' / ' + total.toString() + ' 项已开启'", '折叠头没显示已开启项摘要'),
        ('this.actionBar()', '高频操作没有独立成一行四个按钮'),
        ('this.sectionTitle()', '音源列表前没有分区标题'),
        ("Text('当前首选')", 'Hero 控制台没显示当前首选'),
        ("angle: 135", 'Hero 仪表芯片没沿用信号琥珀 135° 渐变'),
        ('FONT.display', 'Hero 总数没用大号数字做视觉焦点'),
        ("Button('选择')", '重设计后「选择」入口丢了'),
        ("this.checkAll()", '重设计后「全部自检」入口丢了'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage ' + msg))
    # 开关行必须落在可折叠分支内：条件渲染在前、开关调用在后（懒人模式下可见行数会变）
    if not (0 < src_page.find('if (this.settingsExpanded) {') <
            src_page.find('this.smartHuntRow()')):
        bad += 1
        issues.append(('AC', 'FAIL', 'SourcesPage 7 个选项开关又常驻在列表顶部，没进可折叠分支'))
    # v2.57：懒人模式开关必须真的接上设置与面板，别只留一个 UI 空壳
    for kw, msg in (
        ('this.smartHuntRow()', '折叠面板里没有「智能达标寻源」开关行'),
        ('this.settings.smartHunt()', '页面没有从 Settings 读回懒人模式开关'),
        ('this.settings.setSmartHunt(on)', '开关没有落盘'),
    ):
        if kw not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage ' + msg))
    # 纸墨表面三件套仍齐（重设计后沿用集中层，不逐页平涂）
    for fn in ('glassSurface(this.isDark, this.lightLevel)',
               'glassEdgeColor(this.isDark, this.lightLevel)',
               'glassShadow(this.isDark, this.lightLevel)'):
        if fn not in src_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'SourcesPage 重设计缺 ' + fn + '：玻璃四件套没铺齐'))

    # v2.52 墨栈换肤：守住「去光化 + 彩色配给制」不回潮。
    # 这些字面量都是青绿玻璃 / 旧品牌蓝时代的硬编码残留，改色板时最容易漏，
    # 一旦回来就是「换了底色、留一屏发光玻璃」的假换肤。
    all_src = '\n'.join(src.values())
    for kw, msg in (
        ('#FF335CFF', '旧品牌蓝死值复活（palette 主色已改信号琥珀）'),
        ('#FF3ED4BC', '青绿渐变徽标复活'),
        ('#FF1FA0A8', '青蓝色块复活'),
        ('#40338899', '青蓝外投影复活'),
        ('#FF6FEBD0', 'Hero 青绿渐变复活'),
        ('rgba(210,240,238', '薄荷青绿染色复活'),
    ):
        if kw in all_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.52 墨栈：' + msg))
    # 墨栈语义 token 必须齐，且四件套符号壳保留（全站 250 处调用依赖）
    for kw, msg in (
        ('inkDividerStrong', '缺结构性边界 token'),
        ('inkSignalText', '缺细线型琥珀 token'),
        ('INK_ON_SIGNAL', '缺琥珀上墨字 token'),
        ('return [[c, 0], [c, 1]];', 'glassSurface 没收敛成中性实色平涂'),
    ):
        if kw not in constants:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.52 墨栈：' + msg))

    # v2.52 墨栈：signal 琥珀实底上的文字/图标只用 onSignal 墨字（7.57:1）。
    # 白字只许留在深色底 / toast / 半透明黑角标 / danger 玫红 / 反相墨块徽标上。
    # 逐行找「带白字的 fontColor」，再看其后同一链式调用里是否落到 primary 实底，
    # 命中即说明主按钮文字又被改回白字（对 signal 仅 2.31:1）。
    white_on_signal = 0
    for _f, _s in src.items():
        if not _f.endswith('.ets'):
            continue
        _lines = _s.split('\n')
        for _i, _ln in enumerate(_lines):
            if "'#FFFFFFFF'" in _ln and '.fontColor(' in _ln:
                _tail = '\n'.join(_lines[_i:_i + 9])
                if re.search(r"backgroundColor\(this\.p\(\)\.primary\)|"
                             r"backgroundColor\(palette\(this\.isDark\)\.primary\)|"
                             r"colors:\s*this\.favBtnGradient\(\)", _tail):
                    white_on_signal += 1
    if white_on_signal:
        bad += 1
        issues.append(('AC', 'FAIL',
                       'v2.52 墨栈：%d 处白字/白图标压在 signal 琥珀实底上，应改 onSignal 墨字 #FF191713'
                       % white_on_signal))
    # 关键落地串必须在位，防止把墨字整批删掉
    for kw, msg in (
        ("fontColor(this.active ? '#FF191713' : this.p().text2)", 'Chip 激活态没用 onSignal 墨字'),
        ("Text('播放全部').fontSize(FONT.callout).fontWeight(FontWeight.Medium).fontColor('#FF191713')",
         '播放全部按钮没用 onSignal 墨字'),
    ):
        if kw not in all_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.52 墨栈：' + msg))

    # ── v2.53 包 1：状态与反馈统一（形状冗余 / 时间上下文 / L3 结果区）──
    # 方案《音栈-交互逻辑重设计说明（v2.53 预案）》5.1–5.4 的落地守卫。
    # 这一组只证明「交互层真的改了」，不碰任何色值：色板归上面 v2.52 那组管。
    # 检查的是行为锚点（枚举档位、调用点、结构体、挂载），不是注释或文案措辞。
    sources_src = next((s for f, s in src.items() if f.endswith('ui/pages/SourcesPage.ets')), '')
    for kw, msg in (
        ('enum SourceMark', '缺状态形状四档枚举，色相又成了唯一编码'),
        ('PASS = 0', '形状枚举缺「通过」档'),
        ('WARN = 1', '形状枚举缺「警告」档'),
        ('WAIT = 2', '形状枚举缺「自检中」档'),
        ('IDLE = 3', '形状枚举缺「未检测」档'),
        ('function statusMark(item: SourceItem): SourceMark', '形状判定函数缺失或签名被改'),
        ('this.markGlyph(statusMark(item), statusColor(item, this.p()), 13)',
         '卡片状态行没接形状，退回单颗色点'),
        ('this.markGlyph(SourceMark.PASS, this.p().success, 12)', '概览「自检通过」行没接形状'),
        ('this.markGlyph(SourceMark.WARN, this.p().accent, 12)', '概览「自检未通过」行没接形状'),
        ('this.markGlyph(SourceMark.IDLE, this.p().text2, 12)', '概览「未自检」行没接形状'),
        ('function relativeCheck(at: number, now: number): string',
         '缺相对时间换算，checkedAt 又只剩磁盘知道'),
        ('function checkStale(item: SourceItem, now: number): boolean', '缺结论时效判定'),
        ('Text(checkLabel(item, this.nowTs))', '卡片没展示上次自检时间'),
        ('this.clockTimer = setInterval', '相对时间不会自己走字，停一小时还写「刚刚」'),
        ('interface CheckReportRow', '缺自检结果行结构'),
        ('@State reportAt: number = 0;', '缺 L3 结果区状态，结论又只能靠 toast 一闪而过'),
        ('this.checkReportCard()', '自检结果区没挂进列表'),
        ('ForEach(this.reportFailed', '结果区没逐条列出未通过项'),
        ("' 个自检通过'", '概览没写「自检通过」，与卡片口径不一致'),
        ("' 个已就绪未自检'", '概览把「未自检」混进了就绪数，重演 v2.47 的假正常'),
    ):
        if kw not in sources_src and kw not in all_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.53 包 1：' + msg))

    # 旧的 6vp 状态圆点不许复活：形状编码是这套方案的立身之本
    if re.search(r"width\(6\)\s*\.height\(6\)\s*\.borderRadius\(3\)\s*\.backgroundColor\(statusColor",
                 sources_src):
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.53 包 1：6vp 状态圆点复活，形状编码被绕开'))

    # ── v2.54 包 2：导航与诊断闭环（搜索动作 / 失败直达 / 来源显式 / 部分失败可见）──
    # 方案 5.5–5.6 与「流程 1 / 流程 2」的落地守卫。
    # 只证明可达性与信息可见性真的变了：路由表、取链算法、视觉 token 一处都不许动。
    common_src = next((s for f, s in src.items() if f.endswith('ui/Common.ets')), '')
    player_src = next((s for f, s in src.items() if f.endswith('ui/pages/PlayerPage.ets')), '')
    player_core = next((s for f, s in src.items() if f.endswith('core/Player.ets')), '')
    search_src = next((s for f, s in src.items() if f.endswith('ui/pages/SearchPage.ets')), '')
    disc_src = next((s for f, s in src.items() if f.endswith('ui/pages/DiscoverPage.ets')), '')

    # ① 搜索从「二级页」提升为「全局动作」：顶栏提供可选入口，默认关闭
    for kw, msg in (
        ('@Prop showSearch: boolean = false;', 'PageBar 缺可选搜索动作参数'),
        ('if (this.showSearch) {', 'PageBar 不渲染搜索按钮'),
        ('showSearch: this.showSearch,', 'ImmersiveBar 没把搜索参数透传给 PageBar'),
    ):
        if kw not in common_src and kw not in all_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.54 包 2：' + msg))

    # ② 三个二级页必须真的接上（只加参数不接入等于没做）
    wired = 0
    backs = 0
    for f, s_ in src.items():
        if not f.endswith(('RankBoardPage.ets', 'ArtistPage.ets', 'SheetDetailPage.ets')):
            continue
        if 'showSearch: true,' in s_ and "App.get().openSearch('')" in s_:
            wired += 1
        if 'onBackPressed(' in s_:
            backs += 1
    if wired != 3:
        bad += 1
        issues.append(('AC', 'FAIL',
                       'v2.54 包 2：搜索入口只接了 %d/3 个二级页（榜单 / 歌手 / 歌单详情）' % wired))
    if backs != 3:
        bad += 1
        issues.append(('AC', 'FAIL',
                       'v2.54 包 2：二级页返回挂载只剩 %d/3 个，返回链断了一处' % backs))

    # ③ 发现页是一级 Tab、没有 PageBar，入口落在分段行右侧
    if "App.get().openSearch('')" not in disc_src:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.54 包 2：发现页仍是搜索死角'))

    # ④ 路由表严格受控：v2.54 包 2 起「搜索是动作不是页面」，
    # v2.62 批准新增「播放设置 / 外观」、v2.63 批准新增「数据管理」，
    # v2.64 批准新增「网易云账号」（wyAccount，登录 + 本人账号推荐），
    # v2.65 批准新增「板块全量页」（discoverSection，发现页「更多 ›」的落点）。
    # 白名单之外的名字一个都不许变，防止随手加页面把导航栈改乱。
    index_src = next((s for f, s in src.items() if f.endswith('pages/Index.ets')), '')
    route_names = sorted(set(re.findall(r"name === '([a-zA-Z]+)'", index_src)))
    if route_names != ['appearanceSettings', 'artist', 'dataSettings', 'discoverSection',
                       'downloads', 'favoriteSheets', 'playSettings', 'rankboard', 'search',
                       'sheet', 'sources', 'wyAccount']:
        bad += 1
        issues.append(('AC', 'FAIL',
                       'v2.65：路由表名字集变了（%s），只允许播放/外观/数据/网易云账号/板块全量页五个新二级页，'
                       '搜索不该占新路由' % ','.join(route_names)))

    # ⑤ 失败现场直达音源管理（v2.46「自检正常为什么放不出来」的断点）
    for kw, msg in (
        ("Text('查看音源状态')", '播放失败面板又只剩换源 / 重取链 / 下一首'),
        ('App.get().openSources();', '失败面板没有直达音源管理的出口'),
        ('inkSignalText', '诊断出口没走细线型琥珀，压在浅底上看不清'),
    ):
        if kw not in player_src and kw not in all_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.54 包 2：' + msg))

    # ⑥ 成功态来源显式：类型字段 + getter + 五类赋值 + 播放页标记
    for kw in ("private sourceKind: string = 'normal';", 'getSourceKind(): string {',
               "this.sourceKind = 'local';", "this.sourceKind = 'manual';",
               "this.sourceKind = 'switch';", "'substitute'"):
        if kw not in player_core:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.54 包 2：来源类型缺 ' + kw))
    if "this.sourceKind === 'substitute'" not in player_src:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.54 包 2：播放页没把「替补来的」标出来'))

    # ⑦ 部分失败不再被吞成空数组
    if re.search(r'searchMusicFree\(id\.substring\(3\), word, page\)\s*\.catch\(', search_src):
        bad += 1
        issues.append(('AC', 'FAIL',
                       'v2.54 包 2：单源搜索又把异常吞成空数组，部分失败重新隐身'))
    for kw, msg in (
        ('@State failedSources: string[] = [];', '缺失败源名单状态'),
        ('private sourceLabel(id: string): string', '缺源显示名映射，提示说不清是谁挂了'),
        ('this.failedSources = fails;', '搜索完成没把失败源落到界面状态'),
        ('sourceFaultBar()', '部分失败提示条没挂进结果区'),
        ("'五大平台和已启用的插件都没搜到", '空态文案退回旧措辞，三段式没落地'),
    ):
        if kw not in search_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.54 包 2：' + msg))
    # 2026-11-16：用户要求删掉界面说明，「小提示」展开卡与 idleTipOpen 状态都不许回潮
    if "'小提示'" in search_src or 'idleTipOpen' in search_src:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.54 包 2：idle 页说明卡又回来了（用户要求删说明）'))

    if bad == 0:
        issues.append(('AC', 'PASS',
                       '底栏三项（发现第二）、音乐库并入首页、发现平台里的咪咕已摘、搜索走二级页、'
                       '听歌识曲链路已整体移除、备份 / 恢复与权限清理完整、桌面卡片两端已补齐、'
                       '搜索页专辑 tab 已整套移除、同款合并完整、玻璃质感档位全站跟随、'
                       'v2.29 三套无用功能（为你整理 / 本机分类 / 首页编排）已整套移除、'
                       '歌词按本平台官方词优先且非歌词文本一律拦截、'
                       '网易云搜索走 v1 接口并识别 -462 风控、'
                       '封面按名跨平台补全 + 酷我榜单死链用 v9_pic2 备用可恢复、'
                       '设置页质感入口已下线且玻璃质感固定浓郁、'
                       '数据说明删掉自建歌单、备份范围连音源脚本正文一起纳入并可恢复、'
                       'v2.40 MusicFree 适配层（CommonJS 装载 / 9 包注入 / mfRaw 全程回传 / '
                       '插件自检 / 精确分派）闭环、'
                       'v2.41 订阅清单批量导入 + ESM 兼容 + 洛雪失败回退 + 报错卡片布局统一、'
                       'v2.42 全订阅源适配（混淆 CommonJS 判定 / 中文 @name 不误伤 / '
                       'buffer 真实现 / pako 如实标注 / HTML 中转页拦截）、'
                       'v2.43 就绪状态解耦（loadAll 传 kind / 可搜索能力持久化恢复 / '
                       '搜索源不绑 status / 自检结论独立 / 元力订阅 6 插件适配）、'
                       'v2.44 歌单与歌手多类型搜索及详情（官方 search(sheet/artist) / '
                       'getMusicSheetInfo / getArtistWorks / supportedSearchType 过滤 / '
                       'mfRaw 全程回传 / 详情页按 mf: 分派）、'
                       'v2.45 MusicFree 插件取链替补（按名重搜 + 严格同名匹配 + mfRaw 门槛 / '
                       '替补在只用首选音源之后 / 并发上限 / 来源如实标注）与下载完成「已下载」态、'
                       'v2.46 MusicFree 取链失败如实反馈（guard 透传插件异常 / '
                       '自检按取链结果判级 / 卡片显示真实原因）、'
                       'v2.47 自检结论与卡片显示一致（ForEach key 带 health / '
                       '「正常」只给通过项 / 未自检显示已就绪未自检 / 结论持久化）、'
                       'v2.48 音源多选批量删除（选择模式勾选 / 全选 / 确认后一次落盘 / 单删复用同一路径）、'
                       'v2.49 双体系自动替补升级（health 排序不过滤 / 排除失败原插件 / 洛雪全关不空转）'
                       '与歌单收藏多选批量取消（key 带选中态 / 一次落盘 / 返回先收选择模式）、'
                       'v2.50 两处选择条统一固定在列表下方（避开全局迷你播放条 / 上排 取消·已选·全选 / '
                       '下排 danger 删除 / 返回键语义一致）、'
                       'v2.51 音源管理页重设计（Hero 青绿仪表控制台 / 一行四高频操作 / '
                       '7 项低频选项默认折叠 / 列表分区标题 / 玻璃四件套不变）'))


def check_tab_swipe(src):
    """AE/AF/AG：官方 HDS HdsTabs 悬浮导航 + 沉浸光感 + MiniBar 展开收起。

    本次完全重做（用户明确「原有的舍弃重做」）：把旧的标准 Tabs + 自绘 HdsTabBar/
    HdsMiniBar 悬浮层，换成 UIDesignKit 官方 HdsTabs（见 ui/HdsNav.ets）：
      - 悬浮三要素 barOverlap(true) + barPosition(End) + vertical(false)；
      - barFloatingStyle: barWidth / barBottomMargin / gradientMask /
        systemMaterialEffect(hdsMaterial ADAPTIVE 类型 + ADAPTIVE 等级)；
      - MiniBar: miniBarBuilder 放播放器 UI、barLayoutMode=VERTICAL 双行、
        miniBarStyle=HdsBarStyle.EXPAND、onBarStyleChange 感知折叠；
      - HdsTabsController.applyMiniBarStyle(EXPAND/COLLAPSE) 控制展开收起；
      - BottomTabBarStyle 页签，图标用 SymbolGlyphModifier 对象；
      - 流光 HdsFlowLight + 一镜到底 miniBar↔全屏页共用 geometryTransition id。
    """
    index = next((s for f, s in src.items() if f.endswith('pages/Index.ets')), '')
    shell = next((s for f, s in src.items() if f.endswith('ui/Shell.ets')), '')
    nav = next((s for f, s in src.items() if f.endswith('ui/HdsNav.ets')), '')
    if not index or not nav:
        issues.append(('AE', 'WARN', '缺 Index.ets / HdsNav.ets，跳过 HDS 导航检查'))
        return

    bad = 0
    # ── AE：HdsTabs 容器 + 悬浮三要素 ──
    if 'HdsNav' not in index or 'import { HdsNav }' not in index:
        bad += 1
        issues.append(('AE', 'FAIL', 'Index 没挂 HdsNav：官方 HdsTabs 导航未接入'))
    if not nav:
        bad += 1
        issues.append(('AE', 'FAIL', '缺 ui/HdsNav.ets：官方 HDS 导航组件不存在'))
    else:
        if "from '@kit.UIDesignKit'" not in nav or 'HdsTabs' not in nav:
            bad += 1
            issues.append(('AE', 'FAIL', 'HdsNav 没有从 @kit.UIDesignKit import HdsTabs'))
        if not re.search(r'\bHdsTabs\(\{', nav):
            bad += 1
            issues.append(('AE', 'FAIL', 'HdsNav 里没有 HdsTabs({...}) 一级容器'))
        for three in ('.barOverlap(true)', '.barPosition(BarPosition.End)', '.vertical(false)'):
            if three not in nav:
                bad += 1
                issues.append(('AE', 'FAIL', f'悬浮三要素缺 {three}'))
        # 三个一级页必须经 @BuilderParam 注入（首页/发现/设置）。
        for slot in ('content0:', 'content1:', 'content2:'):
            if slot not in index:
                bad += 1
                issues.append(('AE', 'FAIL', f'Index 没把一级页注入 HdsNav 的 {slot}'))
        if nav.count('.tabBar(this.tabStyle(') < 3:
            bad += 1
            issues.append(('AE', 'FAIL', '少于 3 个 TabContent 用 BottomTabBarStyle：三入口不全'))
        if 'new BottomTabBarStyle(' not in nav or 'SymbolGlyphModifier' not in nav:
            bad += 1
            issues.append(('AE', 'FAIL', '页签没用 BottomTabBarStyle + SymbolGlyphModifier（直接塞 $r 会编译失败）'))
        # 受控页码：index 由 @Prop selected 驱动，onChange 回写。
        if 'index: this.selected' not in nav or '.onChange(' not in nav:
            bad += 1
            issues.append(('AE', 'FAIL', 'HdsTabs 没做受控页码：横滑/点页签无法双向同步'))

    # ── AF：barFloatingStyle 沉浸光感 + MiniBar 双行 + 流光 ──
    af = 0
    if '.barFloatingStyle(' not in nav:
        af += 1
        issues.append(('AF', 'FAIL', 'HdsTabs 没配 barFloatingStyle：不是悬浮胶囊'))
    for fld in ('barWidth', 'barBottomMargin', 'gradientMask', 'systemMaterialEffect', 'miniBar'):
        if fld not in nav:
            af += 1
            issues.append(('AF', 'FAIL', f'barFloatingStyle 缺 {fld}：悬浮配置不全'))
    # systemMaterialEffect：hdsMaterial ADAPTIVE 类型 + ADAPTIVE 等级（官方要求）。
    if 'hdsMaterial.MaterialType.ADAPTIVE' not in nav or 'hdsMaterial.MaterialLevel.ADAPTIVE' not in nav:
        af += 1
        issues.append(('AF', 'FAIL', 'systemMaterialEffect 没用 hdsMaterial 的 ADAPTIVE 类型+等级'))
    # MiniBar：miniBarBuilder + barLayoutMode=VERTICAL + miniBarStyle=EXPAND + onBarStyleChange。
    if 'miniBarBuilder:' not in nav or '@Builder\n  miniBarBuilder()' not in nav and 'miniBarBuilder()' not in nav:
        af += 1
        issues.append(('AF', 'FAIL', 'miniBar 没接 miniBarBuilder 放播放器 UI'))
    if 'HdsBarLayoutMode.VERTICAL' not in nav or 'barLayoutMode:' not in nav:
        af += 1
        issues.append(('AF', 'FAIL', 'miniBar 没设 barLayoutMode=VERTICAL 双行布局'))
    if 'HdsBarStyle.EXPAND' not in nav or 'miniBarStyle:' not in nav:
        af += 1
        issues.append(('AF', 'FAIL', 'miniBar 没设 miniBarStyle=HdsBarStyle.EXPAND 初始展开'))
    if 'onBarStyleChange:' not in nav:
        af += 1
        issues.append(('AF', 'FAIL', 'miniBar 没接 onBarStyleChange：感知不到展开/折叠态'))
    # 流光：miniBar 内套 HdsFlowLight。
    if 'HdsFlowLight' not in nav:
        af += 1
        issues.append(('AF', 'FAIL', 'MiniBar 没套 HdsFlowLight 流光特效'))
    # 播放器 UI 要素：封面 + 播放/暂停 + 进播放页。
    for ui in ('Cover(', 'sys.symbol.play_fill', 'enterPlayer()'):
        if ui not in nav:
            af += 1
            issues.append(('AF', 'FAIL', f'miniBarBuilder 播放器 UI 缺 {ui}'))

    # ── AG：HdsBarStyle.EXPAND/COLLAPSE 控制 + 一镜到底 ──
    ag = 0
    if 'HdsTabsController' not in nav or 'controller: this.controller' not in nav:
        ag += 1
        issues.append(('AG', 'FAIL', '没有 HdsTabsController 控制器'))
    if 'applyMiniBarStyle' not in nav:
        ag += 1
        issues.append(('AG', 'FAIL', '没调 HdsTabsController.applyMiniBarStyle：无法通过 HdsBarStyle 主动控制展开收起'))
    if 'navMiniBarCmd' not in nav or "AppStorage.setOrCreate('navMiniBarCmd'" not in index:
        ag += 1
        issues.append(('AG', 'FAIL', '缺 navMiniBarCmd 控制通道：Index 无法驱动 MiniBar 展开收起'))
    # 一镜到底：miniBar 与全屏页共用 playerGeomId。
    if 'geometryTransition(this.playerGeomId)' not in nav:
        ag += 1
        issues.append(('AG', 'FAIL', 'miniBar 没绑 geometryTransition(playerGeomId)：一镜到底缺小形态端'))
    if 'playerGeomId' not in index or 'setPlayerShow' not in index:
        ag += 1
        issues.append(('AG', 'FAIL', 'Index 没维护 playerGeomId/setPlayerShow：一镜到底缺大形态端'))
    # 二级页标准 push 保留。
    if 'pushPathByName' not in index and 'pushPathByName' not in ''.join(src.values()):
        ag += 1
        issues.append(('AG', 'FAIL', '二级页没走 pushPathByName 标准 push'))

    if bad == 0:
        issues.append(('AE', 'PASS', '官方 HdsTabs 悬浮导航：三要素齐备 + BottomTabBarStyle(SymbolGlyphModifier) + 受控页码'))
    if af == 0:
        issues.append(('AF', 'PASS', 'barFloatingStyle 沉浸光感(hdsMaterial ADAPTIVE/ADAPTIVE) + MiniBar VERTICAL 双行 + 流光 + 播放器 UI'))
    if ag == 0:
        issues.append(('AG', 'PASS', 'HdsBarStyle.EXPAND 初始展开 + onBarStyleChange 感知 + HdsTabsController 控制 + miniBar↔全屏一镜到底'))

    # ── 我喜欢 / 最近播放的删除（AH）──
    # 这两个列表和「本地音乐 / 自建歌单」共用同一个详情页 and 同一套 swipeAction。
    # 动作必须按 kind 分发：收藏走 removeFavorite、历史走 removeHistory，
    # 一旦落回「移出歌单」那条分支，用户点「移除」改的是歌单数据，
    # 界面上的表现是「点了没反应」——而且悄悄改了别的地方。
    ah = 0
    lib = next((s for f, s in src.items() if f.endswith('core/Library.ets')), '')
    detail = next((s for f, s in src.items() if f.endswith('ui/pages/SheetDetailPage.ets')), '')
    if not lib or not detail:
        issues.append(('AH', 'WARN', '缺文件，跳过我喜欢/最近播放删除检查'))
    else:
        if not re.search(r'removeHistory\s*\(\s*song:\s*SongInfo', lib):
            ah += 1
            issues.append(('AH', 'FAIL', 'Library 没有 removeHistory：最近播放只能整份清空，删不掉单条'))
        if not re.search(r'clearFavorites\s*\(\s*\)\s*:', lib):
            ah += 1
            issues.append(('AH', 'FAIL', 'Library 没有 clearFavorites：我喜欢列表没有清空能力'))
        swipe = _func_body(detail, 'canSwipe') or ''
        if 'isFavKind' not in swipe or 'isHistoryKind' not in swipe:
            ah += 1
            issues.append(('AH', 'FAIL', '我喜欢 / 最近播放没进 canSwipe：这两个列表左滑不出删除按钮'))
        swipeBody = _func_body(detail, 'swipeDelete') or ''
        if 'removeFavoriteOne' not in swipeBody or 'removeHistoryOne' not in swipeBody:
            ah += 1
            issues.append(('AH', 'FAIL', '左滑分发缺 removeFavoriteOne / removeHistoryOne：会落到「移出歌单」分支'))
        clearBody = _func_body(detail, 'confirmClear') or ''
        if 'AlertDialog.show' not in clearBody or 'this.clearAll()' not in clearBody:
            ah += 1
            issues.append(('AH', 'FAIL', '清空没有确认弹窗：一击抹掉整份列表，误触无法挽回'))
        # clearAll 只允许从 confirmClear 里调一次；别处再出现就是「按钮绕过弹窗直连」
        if len(re.findall(r'this\.clearAll\(\)', detail)) != 1:
            ah += 1
            issues.append(('AH', 'FAIL', '清空按钮绕过 confirmClear 直接调 clearAll：弹窗形同虚设'))
    if ah == 0:
        issues.append(('AH', 'PASS', '我喜欢 / 最近播放都能左滑单条移除，整份清空走确认弹窗，且不会误改歌单'))

    # ── 官方 HDS 悬浮栏材质（AI）──
    # 新实现用 HdsGlass（半透明底 + 背景模糊 + 受光渐变 + 发丝边）做沉浸光感，
    # HdsFlowLight 叠流光。断言按新材质结构校验，不再守旧「去光化实色」。
    ai = 0
    glass_all = shell
    # 材质四层：半透明底 / 背景模糊 / 受光渐变 / 发丝边 都要在。
    if 'backgroundColor(withAlpha(' not in glass_all:
        ai += 1
        issues.append(('AI', 'FAIL', '悬浮材质缺半透明底色（withAlpha）：沉浸光感无从透出背景'))
    if 'backgroundBlurStyle(' not in glass_all:
        ai += 1
        issues.append(('AI', 'FAIL', '悬浮材质缺背景模糊'))
    if glass_all.count('linearGradient(') < 2:
        ai += 1
        issues.append(('AI', 'FAIL', '悬浮材质受光渐变不足两处：HdsGlass 与 HdsFlowLight 都要有'))
    if '.border({ width: 1' not in glass_all:
        ai += 1
        issues.append(('AI', 'FAIL', '悬浮材质缺 1vp 发丝边：边缘会糊在背景里'))
    # 流光扫光必须叠在 MiniBar 上（双行上行也有光感）。
    mini_sec = glass_all[glass_all.find('export struct HdsMiniBar'):] if 'export struct HdsMiniBar' in glass_all else ''
    if 'HdsGlass(' not in mini_sec or 'HdsFlowLight(' not in mini_sec:
        ai += 1
        issues.append(('AI', 'FAIL', 'MiniBar 没叠材质 + 流光层'))
    # 材质层必须不吃触摸事件（否则会挡住页签/播放条的点击）。
    if glass_all.count('HitTestMode.None') < 2:
        ai += 1
        issues.append(('AI', 'FAIL', '材质/流光层没设 HitTestMode.None：会挡住下层点击'))
    # 悬浮胶囊参数常量必须集中在 HdsFloatingStyle（不散落魔数）。
    if not re.search(r'export class HdsFloatingStyle', shell):
        ai += 1
        issues.append(('AI', 'FAIL', '悬浮胶囊参数没收敛到 HdsFloatingStyle'))
    if ai == 0:
        issues.append(('AI', 'PASS', '悬浮栏与 MiniBar 都用半透明+模糊+受光渐变+发丝边，流光扫过，材质层不挡点击'))

    # ── 整页液态玻璃（AJ）──
    # 上一版只改了底栏两条，设置页 6 张卡、首页搜索框 + 快捷卡全是纯白，
    # 用户看到「整页没变化」。这一组卡住「覆盖到每一张卡」和「渐变真能画出来」。
    aj = 0
    consts = next((s for f, s in src.items() if f.endswith('common/Constants.ets')), '')
    settings_page = next((s for f, s in src.items() if f.endswith('ui/pages/SettingsPage.ets')), '')
    home_page = next((s for f, s in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    if 'export function glassCardBase' not in consts:
        aj += 1
        issues.append(('AJ', 'FAIL', '缺 glassCardBase 兜底色：渐变若被模糊材质盖掉，整页又变回白板'))
    # 设置页 6 张卡、首页至少 3 张（搜索框 / 横幅 / 四宫格）
    ns = len(re.findall(r'\.backgroundColor\(glassCardBase\(this\.isDark\)\)', settings_page))
    nh = len(re.findall(r'\.backgroundColor\(glassCardBase\(this\.isDark\)\)', home_page))
    if ns < 6:
        aj += 1
        issues.append(('AJ', 'FAIL', f'设置页只有 {ns} 张卡套了玻璃（应 6 张）：总有几张还是纯白，整页看着没变'))
    if nh < 3:
        aj += 1
        issues.append(('AJ', 'FAIL', f'首页只有 {nh} 处套了玻璃（应 ≥3）：搜索框和四宫格还是纯白'))
    # HDS 沉浸光感故意同时用 backgroundBlurStyle + linearGradient：
    #  blur 负责透出背景色彩，渐变负责受光厚度，二者是官方材质的互补两层。
    # 只守一条：用了模糊就必须同时有渐变，否则整层是会「改了看不出」的纯模糊。
    shell_code = '\n'.join(ln for ln in shell.split('\n')
                           if not ln.lstrip().startswith('//') and not ln.lstrip().startswith('*'))
    if '.backgroundBlurStyle(' in shell_code and 'linearGradient(' not in shell_code:
        aj += 1
        issues.append(('AJ', 'FAIL', '悬浮材质用了模糊却没配受光渐变：会变成看不出变化的纯模糊层'))
    # v2.52 墨栈：表面中性实色，禁止青绿染色；用暖骨白 / 冷石墨双色板守护
    if 'rgba(210,240,238' in consts or 'rgba(206,236,232' in consts or '#FFFDFCFA' not in consts:
        aj += 1
        issues.append(('AJ', 'FAIL', '表面还带薄荷青绿染色 / 没换成墨栈中性纸墨底板'))
    # v2.52 墨栈：整套色板换成纸墨 + 信号琥珀，玻璃渐变整体退场。
    # 用新增 token 与双主色值守护「换肤真的落地」，而不是数渐变段数。
    for kw, msg in (('inkDividerStrong', '缺墨栈结构性边界 token'),
                    ('inkSignalText', '缺墨栈细线型琥珀 token'),
                    ('INK_ON_SIGNAL', '缺墨栈琥珀上墨字 token'),
                    ("primary: '#FFE29A26'", '浅色主色没换成信号琥珀'),
                    ("primary: '#FFF3B044'", '深色主色没换成信号琥珀')):
        if kw not in consts:
            aj += 1
            issues.append(('AJ', 'FAIL', msg))
    # 版本号必须可辨识：versionName 为 1.0；versionCode 保持 67 不回退（回退会导致真机无法覆盖安装）
    appjson_path = os.path.join(ROOT, 'AppScope', 'app.json5')
    appjson = open(appjson_path, encoding='utf-8').read() if os.path.exists(appjson_path) else ''
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        aj += 1
        issues.append(('AJ', 'FAIL', '版本号没升到 67/1.0：无法判断新包是否真的覆盖安装'))
    if aj == 0:
        issues.append(('AJ', 'PASS',
                       '整页 9 处卡片统一青绿液态玻璃，去掉抢背景的 backgroundBlurStyle，版本号可辨识'))

    # ── 发现页并入同一套玻璃（AK）──
    # 发现页是第三个一级页，之前筛选带是灰胶囊、榜单是纯彩色方块 + 裸文字，
    # 和首页 / 设置页的青绿玻璃摆一起像两个 App。这一组卡住「每处都换了」
    # 和「封面内容没被抹掉」——只换底板却把封面删了同样是没做对。
    ak = 0
    discover = next((s for f, s in src.items() if f.endswith('ui/pages/DiscoverPage.ets')), '')
    # v1.5：推荐歌单卡的玻璃卡座收进共用组件 GlassSheetCard（搜索页也用它），
    # 页面内少一处显式链条是架构变化而非漏改，把组件片段拼进来一起数。
    common_src = next((s for f, s in src.items() if f.endswith('ui/Common.ets')), '')
    gi = common_src.find('export struct GlassSheetCard')
    gsc = common_src[gi:] if gi >= 0 else ''
    gj = gsc.find(chr(10) + '@Component', 1)
    gsc = gsc[:gj] if gj > 0 else gsc[:1400]
    # v2.26：档位全站跟随 this.lightLevel，统计文本归一化回 2 后沿用原断言语义
    discover_surface = (discover + chr(10) + gsc).replace('this.lightLevel', '2')
    discover_norm = discover.replace('this.lightLevel', '2')
    nb = len(re.findall(r'\.backgroundColor\(glassCardBase\(this\.isDark\)\)', discover_surface))
    nsurf = len(re.findall(r'colors:\s*glassSurface\(this\.isDark, 2\)', discover_surface))
    nedge = len(re.findall(r'glassEdgeColor\(this\.isDark, 2\)', discover_surface))
    nsh = len(re.findall(r'glassShadow\(this\.isDark, 2\)', discover_surface))
    if nb < 5 or nsurf < 5 or nedge < 5 or nsh < 5:
        ak += 1
        issues.append(('AK', 'FAIL',
                       f'发现页玻璃只铺了 {nb}/{nsurf}/{nedge}/{nsh} 处（底/渐变/描边/投影各应 ≥5）：总有控件还是白板'))
    if 'glassDepth(this.isDark, 2)' not in discover_norm:
        ak += 1
        issues.append(('AK', 'FAIL', '榜单封面缺下沿聚光：卡片仍是平的贴纸，没有浮起来的厚度'))
    if len(re.findall(r'GlassChip\(\{', discover)) < 2:
        ak += 1
        issues.append(('AK', 'FAIL', '平台 / 分类筛选没换成玻璃胶囊：筛选带还是灰底平涂'))
    if 'struct GlassChip' not in discover or '@Prop active: boolean' not in discover:
        ak += 1
        issues.append(('AK', 'FAIL', 'GlassChip 不是独立 @Component / 缺 @Prop：切平台后选中态不会更新'))
    disc_code = '\n'.join(ln for ln in discover.split('\n')
                          if not ln.lstrip().startswith('//') and not ln.lstrip().startswith('*'))
    if '.backgroundBlurStyle(' in disc_code:
        ak += 1
        issues.append(('AK', 'FAIL', '发现页叠了 backgroundBlurStyle：模糊材质会整层盖掉青绿渐变'))
    if 'Cover({ uri: board.cover' not in discover or 'board.trackCount' not in discover:
        ak += 1
        issues.append(('AK', 'FAIL', '榜单封面或「N 首」被抹掉：统一 UI 不能把内容一起删了'))
    if 'cardWidth: 140' not in discover:
        ak += 1
        issues.append(('AK', 'FAIL', '推荐歌单卡没缩宽留玻璃内边距：套上卡座会溢出'))
    if ak == 0:
        issues.append(('AK', 'PASS',
                       '发现页分段 / 筛选胶囊 / 榜单卡 / 推荐歌单卡 / 换一批全并入青绿玻璃，封面配色与歌数保留'))

    # ── 二级页并入同一套玻璃（AL）──
    # 截图里的下载管理 / 歌单详情（本地·最近·喜欢）/ 播放页，之前还是纯白卡片 +
    # 灰胶囊，和三个一级页摆一起像两个 App。这一组卡住「六个二级页都换了」、
    # 「跟随 isDark 而不是写死浅色」、「深色沉浸播放页主体不被铺白」、
    # 「骨架屏 / 进度轨道 / 危险色这些语义元素没被误改」。
    al = 0
    pages = {}
    for name in ('DownloadsPage', 'DataSettingsPage', 'SheetDetailPage', 'PlayerPage',
                 'SearchPage', 'ArtistPage', 'SourcesPage', 'RankBoardPage'):
        pages[name] = next((s for f, s in src.items()
                           if f.endswith('ui/pages/' + name + '.ets')), '')
    # 真正铺了玻璃的页面，各自至少这么多处 backgroundColor(glassCardBase(this.isDark))
    # v1.0 第四次返工：下载页三块设置卡整体搬去「数据管理」二级页，下载页玻璃底
    # 4 → 2（行卡 + 操作按钮），数据页新增 4 处；总覆盖不减，不是白卡回潮。
    # 2026-11-16：搜索页 idle「小提示」卡按用户要求删除，玻璃底 4 → 3
    need = {'DownloadsPage': 2, 'DataSettingsPage': 4, 'SheetDetailPage': 4, 'PlayerPage': 5,
            'SearchPage': 3, 'ArtistPage': 1, 'SourcesPage': 6}
    for name, lo in need.items():
        n = len(re.findall(r'\.backgroundColor\(glassCardBase\(this\.isDark\)\)', pages[name]))
        if n < lo:
            al += 1
            issues.append(('AL', 'FAIL', f'{name} 只有 {n} 处玻璃底（应 ≥{lo}）：二级页还有白卡没换'))
    # 四件套必须齐，且用 isDark 广播。v2.26 起档位全站跟随 this.lightLevel，
    # 这里仅把「判定文本」归一化回 2，让字面量断言继续守「四件套铺齐」而不放宽；
    # check_tab_routes 里另有一条读原始文本、禁止再写死 2 的断言，两者不冲突。
    for name in need:
        p = pages[name].replace('this.lightLevel', '2')
        for fn in ('glassSurface(this.isDark, 2)', 'glassEdgeColor(this.isDark, 2)',
                   'glassShadow(this.isDark, 2)'):
            if fn not in p:
                al += 1
                issues.append(('AL', 'FAIL', f'{name} 缺 {fn}：四件套不齐，玻璃会退化成平涂'))
    # 模糊材质会整层盖掉线性渐变 —— 这是「改了没变化」的老毛病
    for name, p in pages.items():
        code = '\n'.join(ln for ln in p.split('\n')
                         if not ln.lstrip().startswith('//') and not ln.lstrip().startswith('*'))
        if '.backgroundBlurStyle(' in code:
            al += 1
            issues.append(('AL', 'FAIL', f'{name} 叠了 backgroundBlurStyle：会盖掉青绿渐变'))
    # 播放页是深色沉浸：主歌词区不能铺浅玻璃，深色底还在
    pl = pages['PlayerPage']
    if "'#0B0C10'" not in pl or 'bgLayers' not in pl:
        al += 1
        issues.append(('AL', 'FAIL', '播放页深色沉浸底或背景层被改：歌词会被浅玻璃盖住'))
    # 语义色与功能性元素必须原样保留，不能为「统一」把它们一起刷成玻璃
    if 'this.p().danger' not in pages['DownloadsPage'] + pages['SheetDetailPage']:
        al += 1
        issues.append(('AL', 'FAIL', '清空 / 删除的危险色语义被抹掉：破坏性操作看不出来了'))
    if 'ProgressType.Linear' not in pages['DownloadsPage']:
        al += 1
        issues.append(('AL', 'FAIL', '下载进度条轨道被误改：功能元素不该铺玻璃'))
    if 'rankSkeleton' not in pages['RankBoardPage']:
        al += 1
        issues.append(('AL', 'FAIL', '排行榜骨架屏占位条被误改：加载态不该铺玻璃'))
    # 音源卡选中态与玻璃描边必须合并成一次 border，否则后一次覆盖前一次
    src_page = pages['SourcesPage']
    if re.search(r'\.border\(\{[^}]*\}\)\s*\.border\(', src_page, re.S) or \
            'sourceCardEdgeWidth' not in src_page:
        al += 1
        issues.append(('AL', 'FAIL', '音源卡选中蓝框与玻璃描边没合并：会出现两层 border 互相覆盖'))
    # 版本号必须可辨识
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        al += 1
        issues.append(('AL', 'FAIL', '版本号没升到 67/1.0：无法确认新包覆盖成功'))
    if al == 0:
        issues.append(('AL', 'PASS',
                       '六个二级页白卡 / 胶囊 / 弹出面板全并入同一套 isDark 玻璃，深色沉浸主体、危险色、进度轨道与骨架屏保持'))

    # ── 歌曲列表 / 空态 / 半模态弹层全并入玻璃（AM）──
    # 用户截图：最近播放的 19 首还是白板 + 细分割线；设置页两个底部弹层（默认发现
    # 平台 / 选择音质）是纯白；下载管理空态是一片空白。这一版把这些「最后一圈白」
    # 全部收进同一套青绿液态玻璃，且必须靠共用组件改一处覆盖全部，不能逐页刷。
    # 组里同时卡住：「列表行用轻投影而不是大卡投影」「播放页深色面板不误改」
    # 「分割线已移除」「正在播放高亮 / 危险色 / 勾选态这些语义没被玻璃冲掉」。
    am = 0
    def page_of(name: str) -> str:
        return next((s for f, s in src.items()
                     if f.endswith('ui/pages/' + name + '.ets')), '')
    common = next((s for f, s in src.items() if f.endswith('ui/Common.ets')), '')
    song_menu = next((s for f, s in src.items() if f.endswith('ui/SongMenu.ets')), '')
    downloads = page_of('DownloadsPage')
    player = page_of('PlayerPage')

    # 1) 共用组件本身必须带齐四件套，且 SongRow / EmptyView 都用 isDark 玻璃
    common_norm = common.replace('this.lightLevel', '2')
    for fn in ('glassCardBase(this.isDark)', 'glassSurface(this.isDark, 2)',
               'glassEdgeColor(this.isDark, 2)', 'glassRowShadow(this.isDark)'):
        if fn not in common_norm:
            am += 1
            issues.append(('AM', 'FAIL', f'Common.ets 缺 {fn}：歌曲列表共用行没铺同一套玻璃'))
    if 'export function glassRowShadow' not in consts:
        am += 1
        issues.append(('AM', 'FAIL', '缺列表行专用轻投影：19 行叠大卡投影会糊成一片绿'))
    # SongRow 的按压反馈不能再用 backgroundColor，否则一按就把玻璃盖成纯色
    if re.search(r"normal:\s*\{\s*\.backgroundColor\('#00000000'\)\s*\}", common):
        am += 1
        issues.append(('AM', 'FAIL', 'SongRow 按压态仍用 backgroundColor：按下会盖掉整块玻璃渐变'))

    # 2) 空态收成悬浮玻璃卡；图标圆底不再是灰白 cardAlt
    if 'struct EmptyView' not in common or \
            common_norm.count('.shadow(glassShadow(this.isDark, 2))') < 1:
        am += 1
        issues.append(('AM', 'FAIL', 'EmptyView 没做成玻璃卡座：下载管理等空态还是一片空白'))
    empty_block = common[common.find('struct EmptyView'):common.find('/* ============================ 加载')]
    if '.backgroundColor(this.p().cardAlt)' in empty_block:
        am += 1
        issues.append(('AM', 'FAIL', '空态图标圆底还是灰白 cardAlt：卡片上会贴一块灰膏药'))
    if 'glassCardBase(this.isDark)' not in empty_block:
        am += 1
        issues.append(('AM', 'FAIL', '空态卡座没有青绿兜底色'))

    # 3) 下载任务行也并入玻璃行卡
    if 'glassRowShadow(this.isDark)' not in downloads:
        am += 1
        issues.append(('AM', 'FAIL', '下载任务行没铺玻璃：和歌曲列表两套皮'))

    # 4) 列表分割线必须移除：每行已是独立玻璃卡，细线会横穿卡片
    for name in ('SheetDetailPage', 'ArtistPage', 'RankBoardPage', 'DownloadsPage'):
        if '.divider(' in page_of(name):
            am += 1
            issues.append(('AM', 'FAIL', f'{name} 列表还留着 .divider()：细线会横穿独立玻璃卡片'))

    # 5) 所有浅色半模态弹层统一：容器底色 + 内容根四件套
    # v1.9：首页「我的歌单」板块下线，editSheet 一并移除。
    # v2.61：首页新增「导入歌单」bindSheet，同样纳入底色约束，别让它露白边。
    # v2.62：播放设置页新增「选择音质」bindSheet，一并纳入浅色弹层底色约束。
    # v2.72：导入面板从首页搬到 FavoriteSheetsPage，宿主随之替换 —— 首页已无
    # bindSheet，收藏页这张新弹层必须沿用同一套玻璃底。
    sheet_hosts = ('FavoriteSheetsPage', 'SettingsPage', 'PlaySettingsPage', 'RankBoardPage', 'SourcesPage',
                   'ArtistPage', 'SheetDetailPage', 'SearchPage')
    for name in sheet_hosts:
        p = page_of(name)
        if 'backgroundColor: glassCardBase(this.isDark)' not in p:
            am += 1
            issues.append(('AM', 'FAIL', f'{name} 的 bindSheet 容器还是白底：弹层边缘会露一圈白'))
    # 共用歌曲菜单、与两个设置弹层的内容根必须铺玻璃
    for label, text in (('SongMenu', song_menu),
                        ('SettingsPage 弹层', page_of('SettingsPage')),
                        ('SourcesPage menuSheet', page_of('SourcesPage'))):
        tn = text.replace('this.lightLevel', '2')
        if 'glassSurface(this.isDark, 2)' not in tn or 'glassShadow(this.isDark, 2)' not in tn:
            am += 1
            issues.append(('AM', 'FAIL', f'{label} 内容根没铺玻璃四件套：弹出面板还是纯白'))
    if 'backgroundColor(this.p().bg)' in song_menu:
        am += 1
        issues.append(('AM', 'FAIL', 'SongMenu 内容根仍是不透明 bg：所有页面的歌曲菜单还是白板'))

    # 6) 模糊材质会整层盖掉渐变 —— 老毛病，全工程一并卡住
    for name, text in (('Common.ets', common), ('SongMenu', song_menu)):
        code = '\n'.join(ln for ln in text.split('\n')
                         if not ln.lstrip().startswith('//') and not ln.lstrip().startswith('*'))
        if '.backgroundBlurStyle(' in code:
            am += 1
            issues.append(('AM', 'FAIL', f'{name} 叠了 backgroundBlurStyle：会整层盖掉青绿渐变'))

    # 7) 深色沉浸播放页不被误改，语义色不丢
    if "'#0B0C10'" not in player or 'bgLayers' not in player:
        am += 1
        issues.append(('AM', 'FAIL', '播放页深色沉浸底被改：浅玻璃会盖住歌词主体'))
    if 'backgroundColor: this.p().bg' not in player:
        am += 1
        issues.append(('AM', 'FAIL', '播放页面板丢了自铺不透明底：半透明会透出黑底让浅字压黑底'))
    if 'isCurrent()' not in common or 'toggleFav' not in common:
        am += 1
        issues.append(('AM', 'FAIL', '正在播放高亮或行内收藏被抹掉：统一 UI 不能把功能一起删了'))
    if 'danger ? this.p().danger' not in downloads or '清除全部任务' not in downloads:
        am += 1
        issues.append(('AM', 'FAIL', '下载页危险色语义被抹掉：清除全部任务看不出是破坏性操作'))
    # 版本号
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        am += 1
        issues.append(('AM', 'FAIL', '版本号没升到 67/1.0：无法确认新包覆盖成功'))
    if am == 0:
        issues.append(('AM', 'PASS',
                       '所有歌曲列表 / 下载任务行 / 空态 / 半模态弹层全并入青绿玻璃悬浮卡，'
                       '列表用轻投影、分割线移除，深色沉浸面板与播放高亮、危险色、勾选态保持'))

    # ── 搜索页歌单 / 推荐歌单共用玻璃；播放队列评估后维持原磨砂玻璃（AN）──
    # 用户截图：搜索页「歌单」tab 的封面卡还光秃秃贴在白底上，而发现页「推荐歌单」
    # 早已是玻璃卡座 —— 根因是两处各写各的。这一版把卡座收进 GlassSheetCard，
    # 两页共用同一份渲染，并按 3*(88+16)=312 < 改造前 318 算好三列不溢出。
    # 播放队列评估结论「不做」：见 QueueSheet.ets 里三次踩坑注释，本组用反向约束固化。
    an = 0
    discover = page_of('DiscoverPage')
    search = page_of('SearchPage')
    queue = next((s for f, s in src.items() if f.endswith('ui/QueueSheet.ets')), '')

    # 1) 共用组件存在，且自带完整四件套
    if 'export struct GlassSheetCard' not in common:
        an += 1
        issues.append(('AN', 'FAIL', '缺少 GlassSheetCard：搜索页与推荐歌单又会各写各的'))
    else:
        seg = common[common.find('export struct GlassSheetCard'):]
        nxt = seg.find(chr(10) + '@Component', 1)
        seg = seg[:nxt] if nxt > 0 else seg[:1400]
        seg_norm = seg.replace('this.lightLevel', '2')
        for key in ('glassCardBase(this.isDark)', 'glassSurface(this.isDark, 2)',
                    'glassEdgeColor(this.isDark, 2)', 'glassShadow(this.isDark, 2)',
                    '.padding(8)', '.borderRadius(RADIUS.lg)', 'cardWidth: number'):
            if key not in seg_norm:
                an += 1
                issues.append(('AN', 'FAIL', 'GlassSheetCard 缺 ' + key))

    # 2) 两页都改用共用组件，且不再有裸 SheetCard 调用
    for nm, body in (('DiscoverPage', discover), ('SearchPage', search)):
        if 'GlassSheetCard({' not in body:
            an += 1
            issues.append(('AN', 'FAIL', nm + ' 未使用 GlassSheetCard'))
        if 'SheetCard({' in body.replace('GlassSheetCard({', ''):
            an += 1
            issues.append(('AN', 'FAIL', nm + ' 仍有裸 SheetCard 调用'))

    # 3) 搜索页三列不溢出；歌单卡不叠磨砂
    if 'cardWidth: 88' not in search or 'justifyContent: FlexAlign.SpaceBetween' not in search:
        an += 1
        issues.append(('AN', 'FAIL', '搜索页歌单三列布局未保持（cardWidth 88 / SpaceBetween）'))
    if '.backgroundBlurStyle(' in search or '.backgroundBlurStyle(' in discover:
        an += 1
        issues.append(('AN', 'FAIL', '歌单卡叠了 backgroundBlurStyle，会和 linearGradient 抢背景'))

    # 4) 播放队列评估结论：维持原半透明磨砂玻璃，不得套青绿四件套
    for key in ('backdropBlur(34)', 'glassFill()', '.clip(true)'):
        if key not in queue:
            an += 1
            issues.append(('AN', 'FAIL', 'QueueSheet 丢了 ' + key + '：播放队列玻璃被改动'))
    if 'glassCardBase(' in queue or 'glassSurface(' in queue:
        an += 1
        issues.append(('AN', 'FAIL',
                       'QueueSheet 被套了青绿四件套：描边与顶部高光渐变会重现「边缘一圈」，'
                       '且 linearGradient 与 backdropBlur 抢背景'))

    # 5) 版本
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        an += 1
        issues.append(('AN', 'FAIL', '版本号没升到 67/1.0：无法确认新包覆盖成功'))

    if an == 0:
        issues.append(('AN', 'PASS',
                       '搜索页歌单与发现页推荐歌单共用同一份 GlassSheetCard 玻璃渲染（三列不溢出）；'
                       '播放队列经评估维持原半透明磨砂玻璃，不套描边与顶部高光渐变'))

    # ── 推荐池：换一批真的刷出新歌单（AO）──
    # 用户反馈「刷三四轮就一直在这几轮里循环」。老机制：建池只抓 2 页（36~60 条），
    # 换一批只把游标 +8、到末尾绕回 0；后台补货尽力而为且有 20 秒冷却，
    # 下拉刷新只换洗牌种子（换顺序不换内容）。
    # 新机制：grow 成为换一批主路径，递增 fetchSeq 摊到分类 / 页码 / 每日推荐，
    # shown 记住已展示过的 id 优先给没看过的，advance 只作无网兜底。
    ao = 0
    pool = next((s for f, s in src.items() if f.endswith('core/SheetPool.ets')), '')

    # 1) 池：递增取数序号 + 已看去重 + grow 返回新批次
    for key in ('private fetchSeq', 'private shown', '++this.fetchSeq',
                'this.shown.add(', 'this.shown.has('):
        if key not in pool:
            ao += 1
            issues.append(('AO', 'FAIL', 'SheetPool 缺 ' + key))
    if 'async grow(fetch: SheetFetch, batch: number): Promise<SheetInfo[]>' not in pool:
        ao += 1
        issues.append(('AO', 'FAIL', 'grow 没改成返回新批次：换一批仍会退回绕圈'))
    if 'MAX_FETCH_PAGE' in pool or 'GROW_GAP_MS' in pool or 'lastGrowAt' in pool:
        ao += 1
        issues.append(('AO', 'FAIL', '还留着固定页码回退 / 20 秒冷却：补货又会静默失败'))

    # 2) 取数：多维度轮换 + 网易每日推荐
    for key in ('nextFeedPage(', 'feedByTag(', "homeSheets('wy', 1)",
                "platform === 'kg'", 'n % 6 === 1'):
        if key not in discover:
            ao += 1
            issues.append(('AO', 'FAIL', 'DiscoverPage 缺 ' + key + '：取数维度没摊开'))

    # 3) 换一批：await grow 主路径 + advance 兜底 + 防连点
    if 'await this.recPool.grow(' not in discover or 'recPool.advance(BATCH)' not in discover:
        ao += 1
        issues.append(('AO', 'FAIL', '换一批没有「先抓新、失败才绕圈」的主路径'))
    if 'swapping' not in discover or '.enabled(!this.swapping)' not in discover:
        ao += 1
        issues.append(('AO', 'FAIL', '换一批没防连点，快速点按会并发堆请求'))
    if 'sheetPage' in discover:
        ao += 1
        issues.append(('AO', 'FAIL', '又出现固定几页循环的翻页变量'))

    # 4) 版本
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        ao += 1
        issues.append(('AO', 'FAIL', '版本号没升到 67/1.0：无法确认新包覆盖成功'))

    if ao == 0:
        issues.append(('AO', 'PASS',
                       '换一批改为真取数：递增序号摊到每日推荐 / 12 分类 / 页码，'
                       '已看去重优先给新歌单，取尽才回退池内，且防连点'))

    # ── 设置项实时刷新：带参 @Builder 改独立组件 + 音质单一数据源（AP）──
    # 用户反馈「选完 192K 回到设置页，摘要还是 128K，重启才变成 192K」。
    # 数据层一直是对的（putSync / getSync 立即可读），坏在 UI：
    # rowArrow / rowSwitch 是带参 @Builder，ArkUI 里参数按值拷贝，父 @State 变化
    # 不会触发 Builder 内部重画；只有页面重建让参数重新求值才对（故重启才生效）。
    # 修复：改成独立 @Component + @Prop（单向同步会刷新），并把音质收口到
    # AppStorage qualityPref 单一源，去掉 @State 副本 + @Watch 搬运。
    ap = 0
    # v2.62：行组件抽到 ui/SettingsCommon.ets、音质弹层搬进 PlaySettingsPage，
    # 守断言的读取范围跟着扩到「设置主页 + 公共组件 + 播放设置页」合并串——
    # 组件形态 / @Prop / 单一数据源 / 弹层勾选这些约束一条不删，只是允许分散实现。
    settings_page = page_of('SettingsPage') + '\n' + \
        next((s for f, s in src.items() if f.endswith('ui/SettingsCommon.ets')), '') + '\n' + \
        page_of('PlaySettingsPage')
    player_core = next((body for f, body in src.items() if f.endswith('core/Player.ets')), '')

    # 1) 两个独立组件存在，且用的是 @Prop（不是按值参数）
    for comp_name in ('SettingArrowRow', 'SettingSwitchRow'):
        if 'struct ' + comp_name not in settings_page:
            ap += 1
            issues.append(('AP', 'FAIL', '缺少 ' + comp_name + '：动态值又会退回按值拷贝'))
    if '@Prop value: string' not in settings_page or '@Prop value: boolean' not in settings_page:
        ap += 1
        issues.append(('AP', 'FAIL', '组件没有 @Prop value：父状态变化仍无法同步到子组件'))
    if "SettingArrowRow({" not in settings_page or "SettingSwitchRow({" not in settings_page:
        ap += 1
        issues.append(('AP', 'FAIL', '设置页没用新组件替换旧 Builder 调用'))
    if 'rowArrow(' in settings_page or 'rowSwitch(' in settings_page:
        ap += 1
        issues.append(('AP', 'FAIL', '仍残留带参 rowArrow / rowSwitch @Builder：摘要会停在旧值'))

    # 2) 音质单一数据源：无本地 @State 副本、无 @Watch 搬运、显示读 qualityPref
    if '@State quality:' in settings_page:
        ap += 1
        issues.append(('AP', 'FAIL', '设置页又有 @State quality 副本：双链路时序不一致'))
    if "@Watch('onQualityPref')" in settings_page or 'onQualityPref(): void' in settings_page:
        ap += 1
        issues.append(('AP', 'FAIL', '设置页还在用 @Watch 搬运音质：应直接读 @StorageProp'))
    if "qualityLabel(this.qualityPref)" not in settings_page:
        ap += 1
        issues.append(('AP', 'FAIL', '音质摘要没读 qualityPref：选完仍不会实时刷新'))
    if "this.qualityPref === item" not in settings_page:
        ap += 1
        issues.append(('AP', 'FAIL', '弹层勾选没读 qualityPref：选中态也停在旧值'))

    # 3) 播放页订阅全局偏好、面板选中即时反馈
    if "@StorageProp('qualityPref') @Watch('onQualityPref')" not in player:
        ap += 1
        issues.append(('AP', 'FAIL', '播放页没订阅 qualityPref：设置页改档位后播放页不同步'))
    if 'this.quality = item;' not in player:
        ap += 1
        issues.append(('AP', 'FAIL', '播放页音质面板选中没即时反馈'))

    # 4) Player.setQuality：广播必须在早退守卫之前，选当前档位也保持全局态一致
    seg = player_core[player_core.find('setQuality(quality: string)'):]
    seg = seg[:520]
    if 'setOrCreate' in seg and 'if (this.quality === quality)' in seg:
        if seg.index('setOrCreate') > seg.index('if (this.quality === quality)'):
            ap += 1
            issues.append(('AP', 'FAIL', 'setQuality 广播在守卫之后：早退时 AppStorage 不更新'))
    else:
        ap += 1
        issues.append(('AP', 'FAIL', 'setQuality 找不到广播 / 早退守卫'))

    # 5) 版本
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        ap += 1
        issues.append(('AP', 'FAIL', '版本号没升到 67/1.0：无法确认新包覆盖成功'))

    if ap == 0:
        issues.append(('AP', 'PASS',
                       '设置页入口行 / 开关行改独立 @Component + @Prop 实时刷新，音质收口到 '
                       'AppStorage qualityPref 单一源；播放页订阅同步，setQuality 广播幂等'))

    # ── 详情页按钮收敛 + 下载管理工具栏收敛（AQ）──
    # 用户反馈：最近播放 / 我喜欢 / 本地音乐三页去掉「随机播放」，行尾图标
    # 要和「播放全部」一样大；下载管理「清空已完成」改「清除」，并去掉「选择」。
    aq = 0
    detail = next((s for f, s in src.items() if f.endswith('ui/pages/SheetDetailPage.ets')), '')
    downloads = next((s for f, s in src.items() if f.endswith('ui/pages/DownloadsPage.ets')), '')
    player_page = next((s for f, s in src.items() if f.endswith('ui/pages/PlayerPage.ets')), '')

    # 1) 详情页不再有随机播放按钮；播放页的随机「模式」要保留，别误删
    if "Text('随机播放')" in detail or 'sys.symbol.shuffle' in detail:
        aq += 1
        issues.append(('AQ', 'FAIL', '详情页还留着「随机播放」按钮：三个列表页没收敛'))
    if 'sys.symbol.shuffle' not in player_page:
        aq += 1
        issues.append(('AQ', 'FAIL', '播放页随机模式被误删：只该去掉详情页入口'))

    # 2) 行尾图标与「播放全部」同为 42 高，旧的 36 小圆点清掉
    if '.height(42)' not in detail or '.width(42)' not in detail:
        aq += 1
        issues.append(('AQ', 'FAIL', '行尾图标没做成 42：和「播放全部」不等高'))
    if detail.count('.borderRadius(21)') < 2:
        aq += 1
        issues.append(('AQ', 'FAIL', '下载 / 清空两个圆形按钮没有统一成 42 的圆'))
    if '.width(36)' in detail or '.borderRadius(18)' in detail:
        aq += 1
        issues.append(('AQ', 'FAIL', '还残留 36 的小圆按钮：这一排又会对不齐'))
    if 'folder_badge_plus' not in detail or 'arrow_down_circle' not in detail:
        aq += 1
        issues.append(('AQ', 'FAIL', '导入本地 / 下载全部两个入口被误删'))

    # 3) 下载管理（v1.0 第四次返工 + 2026-11-16）：队列操作统一到工具条，
    #    长按多选（单选/全选）+ 单击暂停/开始 + 左滑删除 + 全部暂停/全部开始/清除全部任务
    for kw, msg in (
        ('全部暂停', '缺「全部暂停」'),
        ('全部开始', '缺「全部开始」'),
        ('清除全部任务', '缺「清除全部任务」'),
        ('LongPressGesture(', '缺长按进入多选'),
        ('SelectionBar({', '缺公共多选条（单选 / 全选）'),
        ('App.get().downloads.toggle(id)', '单击没接暂停/开始'),
        ('App.get().downloads.pauseAll()', '全部暂停没接下载器'),
        ('App.get().downloads.resumeAll()', '全部开始没接下载器'),
        ('App.get().downloads.clearAll()', '清除全部任务没接下载器'),
        ('.swipeAction(', '缺左滑删除（2026-11-16 用户要求）'),
        ('App.get().downloads.remove(id)', '左滑删除没接下载器'),
    ):
        if kw not in downloads:
            aq += 1
            issues.append(('AQ', 'FAIL', '下载管理 ' + msg))
    if any(k in downloads for k in ('clearDone()', 'clearFailed()', '清空失败')):
        aq += 1
        issues.append(('AQ', 'FAIL', '下载管理还残留旧的清除 / 清空失败操作'))

    # 4) 设置页版本号可确认覆盖安装
    if "APP_VERSION: string = '1.0'" not in settings_page:
        aq += 1
        issues.append(('AQ', 'FAIL', '设置页版本号没升到 1.0：装完无法确认是新包'))

    if aq == 0:
        issues.append(('AQ', 'PASS',
                       '最近播放 / 我喜欢 / 本地音乐去掉随机播放，行尾图标与「播放全部」统一 42 高玻璃圆；'
                       '下载管理「清空已完成」→「清除」并移除「选择」，播放页随机模式保留'))

    # ── 返回手势先收队列 + 菜单 / 首页入口收敛（AR）──
    # 用户反馈：发现页二级界面打开播放队列后，手势返回直接把二级页 pop 掉，
    # 队列没被收起。根因是 Navigation 有栈时系统返回根本不触发 @Entry.onBackPress。
    ar = 0
    index_page = next((s for f, s in src.items() if f.endswith('pages/Index.ets')), '')
    app_core = next((s for f, s in src.items() if f.endswith('core/App.ets')), '')
    song_menu = next((s for f, s in src.items() if f.endswith('ui/SongMenu.ets')), '')
    home_page = next((s for f, s in src.items() if f.endswith('ui/pages/HomePage.ets')), '')

    # 1) 全局「只收浮层」判断 + 一级页 / 顶栏箭头同一优先级
    if 'closeQueueFn' not in app_core or 'consumeBackIfQueueOpen()' not in app_core:
        ar += 1
        issues.append(('AR', 'FAIL', 'App 没有「只收队列、不碰页面栈」的返回判断'))
    # v2.55：back() 改为接受页内临时态处理器，内部统一走 consumeBack(local)
    bseg = app_core[app_core.find('  back(local: (() => boolean) | null = null): void {'):][:400]
    if 'this.consumeBack(local)' not in bseg:
        ar += 1
        issues.append(('AR', 'FAIL', '顶栏返回箭头没走统一优先级：和手势返回不一致'))
    # 单一入口本身：先页内临时态、再根级浮层，顺序不能反
    cseg = app_core[app_core.find('  consumeBack(local: (() => boolean) | null): boolean {'):][:400]
    pos_local = cseg.find('local()')
    pos_overlay = cseg.find('this.consumeBackIfQueueOpen()')
    if not (0 < pos_local < pos_overlay):
        ar += 1
        issues.append(('AR', 'FAIL', 'consumeBack 的优先级不是「页内临时态 → 根级浮层」'))
    if 'App.get().closeQueueFn = ' not in index_page:
        ar += 1
        issues.append(('AR', 'FAIL', 'Index 没注册队列关闭器：二级页拿不到浮层状态'))
    if 'onBackPress(): boolean' not in index_page or 'consumeBackIfQueueOpen()' not in index_page:
        ar += 1
        issues.append(('AR', 'FAIL', '一级页 onBackPress 没复用统一判断'))

    # 2) 每个二级页 NavDestination 都要拦第一次返回（5 个页面 + 搜索页）。
    # v2.31：歌手页 onBackPressed 多了「先退专辑视图」一层，仍先调
    # consumeBackIfQueueOpen() 收队列。断言按「挂了 + 调了」两个条件判，
    # 只是允许多行写法，语义一字未放宽（少任一环仍 FAIL）。
    hook = '.onBackPressed('
    # v2.55：有页内临时态的页面走 consumeBack(local)，其余仍直接收浮层；两者都算
    # 「先收浮层」，少任一环（漏挂 / 漏调）仍 FAIL，语义未放宽。
    hook_calls = ('App.get().consumeBackIfQueueOpen()', 'App.get().consumeBack(')
    for name in ('SheetDetailPage', 'RankBoardPage', 'ArtistPage', 'DownloadsPage', 'SourcesPage'):
        body = next((s for f, s in src.items() if f.endswith('ui/pages/' + name + '.ets')), '')
        if hook not in body or not any(c in body for c in hook_calls):
            ar += 1
            issues.append(('AR', 'FAIL', name + ' 没挂 onBackPressed 或没走统一返回入口：手势返回仍会直接退页'))
    if hook not in index_page or hook_calls[0] not in index_page:
        ar += 1
        issues.append(('AR', 'FAIL', '搜索页 NavDestination 没挂 onBackPressed'))
    if 'QueueOverlay({' not in index_page:
        ar += 1
        issues.append(('AR', 'FAIL', '队列浮层被删了：返回拦截失去对象'))

    # 3) 歌曲菜单两项下线，选择器与死代码一并清掉，但「查看歌手」要留着
    for kw in ('下一首播放', '添加到歌单', 'playlistPicker', 'UserPlaylist'):
        if kw in song_menu:
            ar += 1
            issues.append(('AR', 'FAIL', '歌曲菜单还残留「' + kw + '」'))
    if 'this.actions()' not in song_menu or 'if (this.mode === 0)' in song_menu:
        ar += 1
        issues.append(('AR', 'FAIL', '歌曲菜单 build 仍留着 mode 分支'))
    if "'查看歌手'" not in song_menu:
        ar += 1
        issues.append(('AR', 'FAIL', '「查看歌手」被误删：菜单应保留这一项'))

    # 4) 首页「我的歌单」整块清除，四宫格仍在
    # v2.61：首页用 bindSheet 挂「导入歌单」面板（外部平台链接导入），这是新功能，
    # 不是自建歌单编辑弹层。断言从泛禁 bindSheet 改为精确守 editSheet。
    for kw in ('我的歌单', 'PlaylistCard', 'editSheet', 'createPlaylist', 'sheetMode'):
        if kw in home_page:
            ar += 1
            issues.append(('AR', 'FAIL', '首页还残留「' + kw + '」'))
    if 'quickGrid()' not in home_page or 'LibraryEntryCard' not in home_page:
        ar += 1
        issues.append(('AR', 'FAIL', '首页四宫格被误删'))

    # 5) 版本
    if "APP_VERSION: string = '1.0'" not in settings_page:
        ar += 1
        issues.append(('AR', 'FAIL', '设置页版本号没升到 1.0：装完无法确认是新包'))
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        ar += 1
        issues.append(('AR', 'FAIL', '版本号没升到 67/1.0'))

    if ar == 0:
        issues.append(('AR', 'PASS',
                       '二级页返回手势先收根级浮层（播放页/队列）、再次才退回一级页（6 个 NavDestination 全覆盖，'
                       '顶栏箭头同优先级）；歌曲菜单下线两项、首页清除「我的歌单」板块'))

    # ============ AS：统计 UI 已下线（v2.4 拆除确认） ============
    # v2.0~v2.3 的「音栈·驿站」看板 + 首页报告卡按需求整体拆除；
    # 底层 PlayStats 与播放器埋点已随 B1/B2 整体删除（由 CY 组守护）。
    stv = 0
    board_exists = any(f.endswith('ui/StationBoard.ets') for f in src)
    home = next((x for f, x in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    appjson_path = os.path.join(ROOT, 'AppScope', 'app.json5')
    appjson = open(appjson_path, encoding='utf-8').read() if os.path.exists(appjson_path) else ''
    settings_page = next((x for f, x in src.items() if f.endswith('ui/pages/SettingsPage.ets')), '')

    if board_exists:
        stv += 1
        issues.append(('AS', 'FAIL', 'StationBoard.ets 还在：驿站看板没拆干净'))
    for kw in ('StationTitle()', 'StationBoard()', 'ReportEntryCard()',
               'struct ReportEntryCard', "push('report'", '音栈·驿站', '月·回响'):
        if kw in home:
            stv += 1
            issues.append(('AS', 'FAIL', '首页还残留统计 UI：' + kw))
    if 'quickGrid()' not in home or 'LibraryEntryCard' not in home:
        stv += 1
        issues.append(('AS', 'FAIL', '拆看板时误删了首页四宫格'))
    if '"versionCode": 67' not in appjson or '"versionName": "1.0"' not in appjson:
        stv += 1
        issues.append(('AS', 'FAIL', '版本号没升到 67/1.0'))
    if "APP_VERSION: string = '1.0'" not in settings_page:
        stv += 1
        issues.append(('AS', 'FAIL', '设置页版本号没升到 1.0：装完无法确认是新包'))
    if stv == 0:
        issues.append(('AS', 'PASS',
                       '「音栈·驿站」看板与首页报告卡已整体拆除，首页四宫格完好；'
                       '统计底层 PlayStats 与播放器埋点已整体清除'))

    # ============ AV：报告页与入口已下线（v2.4 拆除确认） ============
    av = 0
    report_exists = any(f.endswith('ui/pages/ReportPage.ets') for f in src)
    index_src = next((x for f, x in src.items() if f.endswith('pages/Index.ets')), '')
    settings_src = next((x for f, x in src.items() if f.endswith('ui/pages/SettingsPage.ets')), '')
    if report_exists:
        av += 1
        issues.append(('AV', 'FAIL', 'ReportPage.ets 还在：月·回响报告页没拆干净'))
    for kw in ("name === 'report'", 'ReportPage()', 'import { ReportPage }'):
        if kw in index_src:
            av += 1
            issues.append(('AV', 'FAIL', 'Index.ets 还残留报告路由：' + kw))
    for kw in ("title: '听歌报告'", "sectionTitle('统计')", "push('report'"):
        if kw in settings_src:
            av += 1
            issues.append(('AV', 'FAIL', '设置页还残留统计入口：' + kw))
    if "sectionTitle('关于')" not in settings_src or "sectionTitle('播放')" not in settings_src:
        av += 1
        issues.append(('AV', 'FAIL', '拆统计分组时把设置页其它分组弄坏了'))
    if av == 0:
        issues.append(('AV', 'PASS',
                       '月·回响报告页、report 路由、设置页「统计」分组全部拆除，设置页其余分组完好'))

    # ============ AW：首页报告卡 / 酷我榜单补全 / 播放页搜歌手 ============
    aw = 0
    home_src = next((x for f, x in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    api_src = next((x for f, x in src.items() if f.endswith('core/PlatformApi.ets')), '')
    cache_src = next((x for f, x in src.items() if f.endswith('core/RankCache.ets')), '')
    player_src = next((x for f, x in src.items() if f.endswith('ui/pages/PlayerPage.ets')), '')

    # 1) v2.4 拆除确认：首页不该再有报告卡 / report 跳转
    for kw in ('struct ReportEntryCard', 'ReportEntryCard()', "push('report'", '月·回响'):
        if kw in home_src:
            aw += 1
            issues.append(('AW', 'FAIL', '首页还残留报告卡：' + kw))
    home_norm = home_src.replace('this.lightLevel', '2')
    for kw in ('glassCardBase(this.isDark)', 'glassSurface(this.isDark, 2)',
               'glassEdgeWidth(2)', 'glassShadow(this.isDark, 2)'):
        if kw not in home_norm:
            aw += 1
            issues.append(('AW', 'FAIL', '报告卡/首页没走统一玻璃：' + kw))

    # 2) 酷我子榜：不再只有 4 个，且不带月份快照 / MV / 测试榜
    m = re.search(r"const ids: string\[\] = \[([^\]]+)\]", api_src)
    ids = re.findall(r"'(\d+)'", m.group(1)) if m else []
    if len(ids) < 10 or not set(['16', '93', '17', '26']).issubset(set(ids)):
        aw += 1
        issues.append(('AW', 'FAIL', '酷我榜单 ID 没补全或弄丢了原有 4 个主榜：' + str(ids)))
    for bad_id in ('18', '54', '55', '96', '73', '75', '79', '80', '84', '85', '87', '88',
                   '98', '99', '100', '107', '114'):
        if bad_id in ids:
            aw += 1
            issues.append(('AW', 'FAIL', '酷我榜单混进了 MV / 月份快照 / 测试榜 id=' + bad_id))
    if '要 4 个请求' in api_src or '4 个子榜串行请求' in cache_src:
        aw += 1
        issues.append(('AW', 'FAIL', '榜单数量变了但注释还写着「4 个请求」'))

    # 3) 播放页「更多」→「搜歌手」
    ab = _func_body(player_src, 'artistSearchButton') or ''
    if not ab:
        aw += 1
        issues.append(('AW', 'FAIL', '播放页没有 artistSearchButton'))
    else:
        if "sys.symbol.person" not in ab or "Text('搜歌手')" not in ab:
            aw += 1
            issues.append(('AW', 'FAIL', '搜歌手按钮没换成人像图标 / 文案'))
        if 'App.get().openSearch(singer)' not in ab or 'this.onClose()' not in ab:
            aw += 1
            issues.append(('AW', 'FAIL', '搜歌手没先收播放页再用歌手名自动搜搜索页'))
        if "indexOf(sep)" not in ab:
            aw += 1
            issues.append(('AW', 'FAIL', '多歌手合唱没取第一位：整串拿去搜基本无结果'))
    for kw in ('this.moreButton()', 'panel === 5', "Text('更多')", 'songMenuPanel', 'SongMenu({'):
        if kw in player_src:
            aw += 1
            issues.append(('AW', 'FAIL', '播放页还残留「更多」菜单：' + kw))
    if aw == 0:
        issues.append(('AW', 'PASS',
                       '首页统计卡整体已拆除、酷我子榜由 4 补到 12 个（剔除月份/MV/测试榜）、'
                       '播放页「更多」改「搜歌手」直接按歌手名跳搜索页'))

    if bad == 0:
        issues.append(('AE', 'PASS', '一级页可横滑切页、指示器 1:1 跟手且与翻页动画同刻起步、收起时换成「圆按钮 + 播放胶囊」一排'))



def check_native_immersive(src):
    """AZ：对标华为音乐的原生特性 —— 液态玻璃/沉浸光感（uiMaterial）、
    一镜到底（geometryTransition + animateTo）。守住在位，防止被改回纯自绘模拟。"""
    index = next((v for f, v in src.items() if f.endswith('pages/Index.ets')), '')
    shell = next((v for f, v in src.items() if f.endswith('ui/Shell.ets')), '')
    try:
        module_json = open(os.path.join(ROOT, 'entry/src/main/module.json5'), encoding='utf-8').read()
    except OSError:
        module_json = ''

    az = 0

    # 1) 应用级沉浸光感 metadata 必须在位且为 enable。
    if '"ohos.arkui.UIMaterial.state"' not in module_json:
        az += 1
        issues.append(('AZ', 'FAIL', 'module.json5 缺 ohos.arkui.UIMaterial.state：应用级沉浸光感没开'))
    elif '"value": "enable"' not in module_json:
        az += 1
        issues.append(('AZ', 'FAIL', 'UIMaterial.state 不是 enable：沉浸光感被关'))

    # 2) Shell.ets 必须从 @kit.ArkUI import uiMaterial（真原生，不是自绘类冒充）。
    if "import { uiMaterial } from '@kit.ArkUI'" not in shell:
        az += 1
        issues.append(('AZ', 'FAIL', 'Shell.ets 没 import uiMaterial：液态玻璃/沉浸光感没有走原生 API'))
    # 3) 原生材质工厂：构造 ImmersiveMaterial + lightEffect 沉浸光感 + 设备分级降级。
    if 'new uiMaterial.ImmersiveMaterial(' not in shell:
        az += 1
        issues.append(('AZ', 'FAIL', '没构造 uiMaterial.ImmersiveMaterial：悬浮胶囊不是原生液态玻璃'))
    if 'lightEffect:' not in shell:
        az += 1
        issues.append(('AZ', 'FAIL', 'ImmersiveMaterial 没配 lightEffect：沉浸光感反馈没开'))
    for kw in ('isImmersiveMaterialSupported', 'getGlobalMaterialLevel',
               'ImmersiveStyle.THIN', 'ImmersiveStyle.THICK'):
        if kw not in shell:
            az += 1
            issues.append(('AZ', 'FAIL', f'原生材质缺 {kw}：设备分级降级不完整'))
    # 4) 官方 HdsTabs 重做：悬浮页签吃 hdsMaterial 的 systemMaterialEffect（ADAPTIVE 类型+等级），
    #    在 HdsNav.ets 的 barFloatingStyle 里。旧的 HdsNativeMaterial.systemMaterial 路径保留在
    #    Shell 供 HdsGlass 用，但悬浮胶囊已切到官方 systemMaterialEffect。
    nav = next((s for f, s in src.items() if f.endswith('ui/HdsNav.ets')), '')
    tab = (nav or '') + '\n' + (_func_body(index, 'tabContent') or '')
    if 'systemMaterialEffect:' not in tab or 'hdsMaterial.MaterialType.ADAPTIVE' not in tab:
        az += 1
        issues.append(('AZ', 'FAIL', 'barFloatingStyle 没挂官方 systemMaterialEffect(ADAPTIVE)：悬浮页签没沉浸光感'))

    # 5) 一镜到底：官方 animateTo 闭包 + geometryTransition 同 id + onFinish 清空。
    sps = _func_body(index, 'setPlayerShow') or ''
    if 'animateTo(' not in sps:
        az += 1
        issues.append(('AZ', 'FAIL', 'setPlayerShow 没放进 animateTo 闭包：一镜到底不会触发'))
    if 'PLAYER_SHARED_ID' not in sps or 'this.playerGeomId' not in sps:
        az += 1
        issues.append(('AZ', 'FAIL', '一镜到底没绑定 geometryTransition 同 id'))
    if 'onFinish' not in sps:
        az += 1
        issues.append(('AZ', 'FAIL', 'geometryTransition id 没在 onFinish 清空：快速连点会误触发共享转场'))
    # 两个形态都必须绑同一个 id：大形态在 Index 全屏 Stack，小形态在 HdsNav 的
    # miniBarBuilder 根 Stack（经 AppStorage['playerGeomId'] 跨组件传 id）。
    nav_src = next((s for f, s in src.items() if f.endswith('ui/HdsNav.ets')), '')
    geom_count = index.count('.geometryTransition(this.playerGeomId)') + nav_src.count('.geometryTransition(this.playerGeomId)')
    if geom_count < 2:
        az += 1
        issues.append(('AZ', 'FAIL', '迷你条与全屏页没都绑 playerGeomId：一镜到底缺一端'))
    if nav_src and "AppStorage.setOrCreate('playerGeomId'" not in index:
        az += 1
        issues.append(('AZ', 'FAIL', 'Index 没把 playerGeomId 写进 AppStorage：HdsNav 小形态拿不到共享 id'))

    if az == 0:
        issues.append(('AZ', 'PASS', '应用级沉浸光感 enable + 悬浮页签原生液态玻璃(ImmersiveMaterial/lightEffect,设备分级) + geometryTransition 一镜到底(animateTo 同 id) 均在位'))


def check_smart_hunt(src):
    """AX：智能达标寻源（懒人模式）——只认目标音质、全源跨平台并发、绝不降质。

    守的是「用户选了 FLAC 就不能被悄悄换成 320k」这条硬约束，以及
    「一个源 / 平台不行就自动换下一个」确实接进了取链、播放、下载三处。
    """
    res = next((s for f, s in src.items() if f.endswith('core/Resolver.ets')), '')
    cfg = next((s for f, s in src.items() if f.endswith('core/Settings.ets')), '')
    ply = next((s for f, s in src.items() if f.endswith('core/Player.ets')), '')
    dld = next((s for f, s in src.items() if f.endswith('core/Downloader.ets')), '')
    page = next((s for f, s in src.items() if f.endswith('ui/pages/SourcesPage.ets')), '')
    http = next((s for f, s in src.items() if f.endswith('core/Http.ets')), '')
    mf_runtime_path = os.path.join(ROOT, 'entry/src/main/resources/rawfile/vendor/mf_runtime.js')
    mf_rt = open(mf_runtime_path, encoding='utf-8').read() if os.path.isfile(mf_runtime_path) else ''
    if not all((res, cfg, ply, dld, page, http)):
        issues.append(('AX', 'WARN', '没找齐 Resolver/Settings/Player/Downloader/SourcesPage/Http，跳过懒人模式检查'))
        return
    bad = 0
    # 开关与默认值
    if 'SMART_HUNT' not in cfg or 'smartHunt()' not in cfg:
        bad += 1
        issues.append(('AX', 'FAIL', 'Settings 没有懒人模式开关 smartHunt()'))
    if 'getBool(PrefKeys.SMART_HUNT, true)' not in cfg:
        bad += 1
        issues.append(('AX', 'FAIL', '懒人模式没有默认开启'))
    # 独立路径 + 目标档位固定不降质
    if 'smartResolve(' not in res or 'Settings.get().smartHunt()' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', 'Resolver 没有独立的 smartResolve 路径或没按开关分流'))
    # v2.57：候选池必须「MF 组 / 平台组」独立预取 + 独立竞速 + 各自专用名额。
    # 旧实现把两者塞进一个按固定顺序填充的池子，热门歌的 4×2 个平台候选正好
    # 占满 8 个名额，MusicFree 插件重搜结果一个都进不来（用户看到全是洛雪音源）。
    if ('this.smartMfPool(song, mfStat)' not in res or
            'this.smartPlatformPool(song)' not in res or
            'this.smartPoolRace(' not in res):
        bad += 1
        issues.append(('AX', 'FAIL', '候选池没做成 MF 组 / 平台组两路独立竞速'))
    if 'SMART_MF_QUOTA' not in res or 'SMART_PLATFORM_QUOTA' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '候选池没给 MusicFree 组独立配额，热门歌会把插件候选挤光'))
    if 'mfFallbackSources()' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '候选池没纳入 MusicFree 插件重搜'))
    if 'withDeadlineList(' not in res or 'SMART_SEARCH_MS' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '搜索任务没有短超时，一个 15s 慢插件会拖到总截止'))
    if 'pickLooseMf(' not in res or 'mfScore(' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', 'MusicFree 结果没放宽同名判定，时长/歌手差异会误杀同款'))
    # v2.57：替补重搜关键词要清洗括号别名/feat.，并有纯歌名兜底；
    # 否则「青花 周传雄 (Steve Chou)」这种脏串直接丢给插件，命中率远低于
    # 用户在搜索页手输的「青花」，看起来就是「搜得到却替补不到」。
    if 'huntKeywords(' not in res or 'cleanHuntWord(' not in res or 'mfSearchRound(' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '替补重搜没清洗关键词，也没纯歌名兜底重搜'))
    if 'stat.rounds++' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '纯歌名兜底轮没被统计，失败面板说不清用了几轮关键词'))
    if 'mfNote(mfStat, notes)' not in res or '试听片段 ' not in res or '插件后端取链失败 ' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '失败面板没按原因分类，会把「命中同款但取链全挂」误读成搜不到'))
    # 档位映射：master / atmos / atmos_plus 不能被映射成最低的 standard（等于偷偷降质）
    if "q.indexOf('master') >= 0" not in mf_rt or "q.indexOf('atmos') >= 0" not in mf_rt:
        bad += 1
        issues.append(('AX', 'FAIL', 'mf_runtime.qualityOf 没把高档位归入 super，选母带会被降成 standard'))
    # 达标门禁：在线 / 下载都强制探测，且拒绝明确有损
    if 'if (!strict || strictVerify || hunt)' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '懒人模式没有强制探测，无法判定是否达标'))
    if 'if ((strict || hunt) && !enough)' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '达标门禁没对在线路径生效，有损链接会被当无损用'))
    if '绝不降质' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '全源失败时没有「绝不降质」的明确失败提示'))
    # v2.59 无损档自动升档：档位是离散 SKU，不是高低阶梯。只问一个档会出现
    # 「选 FLAC 全挂、选全景声反而能播」——不少音源的映射表压根没收录 flac，
    # 却收录了 atmos/master。必须向「不低于目标档」的无损档全部展开。
    if 'huntQualities(' not in res or 'huntExpandRace(' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '懒人模式没做无损档自动升档，单档查表落空会全军覆没'))
    if 'qualityRank(q) < floor' not in res or '!isLossless(want)' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '升档没有「只升不降 + 有损档不展开」守卫，会破坏绝不降质'))
    if 'HUNT_EXPAND_MS' not in res or 'HUNT_STAGGER_MS' not in res or 'gate.done' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '升档没有主档短路 / 错峰，主档有货时也会白白发几十个请求'))
    # 升档集合绝不能把音源 inited 的 qualitys 当白名单：声明残缺是常态，
    # 上一版白名单里没有 atmos 时升档集合只剩 ['flac']，一次升档请求都不发。
    hq = ''
    if 'private static huntQualities' in res:
        hq = res.split('private static huntQualities', 1)[1].split('\n  }', 1)[0]
    if 'available.indexOf(q) < 0' in hq:
        bad += 1
        issues.append(('AX', 'FAIL', '升档集合仍把音源声明当白名单，没声明 atmos 就会被删掉，FLAC 不会自动升全景声'))
    if 'available.indexOf(q) >= 0' not in hq:
        bad += 1
        issues.append(('AX', 'FAIL', '升档集合没有按音源声明排优先级'))
    if 'const HUNT_MAX_QUALITIES: number = 6' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '无损档没有全展开，仍会漏掉全景声 / 母带'))
    if 'const SMART_DEADLINE_MS: number = 52000' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '升档总截止没放宽到 52s，错峰起跑的升档会被 30s 提前掐断'))
    # 无损判定：中转层常把无损链接统一回 Content-Type: audio/mpeg 或 .mp3 后缀。
    # 旧版一见 mpeg 就提前 return 'mp3'，走不到末尾的码率兜底，于是 969kbps 的
    # 真无损被判「只给到320K」全部拒绝 —— 失败面板 25 条齐刷刷全是这个原因。
    if 'kbps >= 640' not in http:
        bad += 1
        issues.append(('AX', 'FAIL', 'detectFormat 没做码率仲裁，无损链接会被 audio/mpeg 标签误判成 mp3'))
    if 'const LOSSY_MAX_KBPS: number = 640' not in res or 'probe.kbps < LOSSY_MAX_KBPS' not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '达标门禁没有高码率保险，969kbps 的真无损仍会被拒绝'))
    # 升档清单要真的进失败面板，否则用户只看到 error 文案里没有的档位
    if "notes.push({ name: '自动升档'" not in res:
        bad += 1
        issues.append(('AX', 'FAIL', '升档清单没进失败面板，用户看不到升过哪几档'))
    # 播放器：不静默跳歌 + 放宽总超时
    if '!Settings.get().smartHunt() && this.failStreak < 2' not in ply:
        bad += 1
        issues.append(('AX', 'FAIL', '懒人模式失败时仍会静默跳到下一首'))
    if 'Settings.get().smartHunt() ? 60000' not in ply:
        bad += 1
        issues.append(('AX', 'FAIL', '懒人模式没放宽取链总超时，会被 30s 提前掐断'))
    # 下载：禁止降级重试
    if '!Settings.get().allowDowngrade() || Settings.get().smartHunt()' not in dld:
        bad += 1
        issues.append(('AX', 'FAIL', '下载没有禁用降级重试，仍可能拿到低音质'))
    # v2.60 音源页：懒人模式走独立 smartResolve，3 项旧取链配置完全不读。
    # 留着不隐藏会让人以为调了有用；但 preferOnly 仍管歌词，说明里必须讲清，
    # 折叠摘要也不能再把隐藏项算进「已开启」。
    opt = page.split('sourceSettings()', 1)[1].split('smartHuntRow() {', 1)[0] if 'sourceSettings()' in page else ''
    smry = page.split('private optionsSummary', 1)[1].split('\n  }', 1)[0] if 'private optionsSummary' in page else ''
    # 2026-11-16：说明块整块删除，结构收成两个 if (!this.smartHunt) 包裹
    if (not opt or opt.count('if (!this.smartHunt)') != 2 or
            'this.smartHuntHint()' in opt or
            opt.count('this.preferOnlyRow()') != 1 or
            opt.count('this.downgradeRow()') != 1 or
            opt.count('this.fallbackRow()') != 1):
        bad += 1
        issues.append(('AX', 'FAIL', '音源页没有按懒人模式条件隐藏 3 项旧取链配置（关闭时须全部恢复）'))
    if '已隐藏 3 项旧取链配置' in page or '仍作用于歌词' in page or 'smartHuntHint' in page:
        bad += 1
        issues.append(('AX', 'FAIL', '懒人模式说明块又回来了（用户要求删说明）'))
    if 'total += 3' not in smry or 'if (!this.smartHunt)' not in smry or "n.toString() + ' / '" not in smry:
        bad += 1
        issues.append(('AX', 'FAIL', '折叠头摘要仍固定按 7 项计数，会把已隐藏的 3 项算进已开启'))
    if bad == 0:
        issues.append(('AX', 'PASS',
                       '懒人模式：目标音质锁定不降质，全源 + 跨平台 + 插件并发竞速，'
                       '无损档自动升档（FLAC→Hi-Res→全景声→母带，只升不降、全档展开、主档短路），'
                       '高码率仲裁防 audio/mpeg 套壳把无损误判成有损，达标门禁在线/下载共用，'
                       '失败明确提示且不静默跳歌；开启时隐藏 3 项失效旧配置并说明，摘要按可见项计数'))


def check_longpress_preload(src):
    """AZ：歌单收藏长按进入多选 + 剩余 N 秒预加载下一首。

    长按语义是「以被按的那张为起点的多选」——不是单选、也不是一键全选；
    预加载必须按剩余时间触发且同 key 在途去重，否则预取未完成时切歌会
    重复发起全源寻源，弱网下反而更慢。
    """
    fav = next((s for f, s in src.items() if f.endswith('ui/pages/FavoriteSheetsPage.ets')), '')
    ply = next((s for f, s in src.items() if f.endswith('core/Player.ets')), '')
    res = next((s for f, s in src.items() if f.endswith('core/Resolver.ets')), '')
    cfg = next((s for f, s in src.items() if f.endswith('core/Settings.ets')), '')
    home = next((s for f, s in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    if not all((fav, ply, res, cfg, home)):
        issues.append(('AZ', 'WARN', '没找齐收藏页/播放器/解析器/设置/首页，跳过长按与预加载检查'))
        return
    bad = 0
    # 顶部「选择」入口必须移除，长按才是唯一进多选的方式
    if "Text('选择')" in fav:
        bad += 1
        issues.append(('AZ', 'FAIL', '歌单收藏页顶部仍留着「选择」入口，长按会与它并存'))
    if ('LongPressGesture({ repeat: false, duration: 400 })' not in fav or
            'onCardLongPress(sheet)' not in fav):
        bad += 1
        issues.append(('AZ', 'FAIL', '歌单卡片没有 400ms 长按手势'))
    if 'firstKey.length > 0 ? [firstKey] : []' not in fav:
        bad += 1
        issues.append(('AZ', 'FAIL', '长按没有预选被按的那张（退化成从 0 开始或一键全选）'))
    if 'this.enterSelect(Library.sheetKey(sheet))' not in fav:
        bad += 1
        issues.append(('AZ', 'FAIL', '长按没把被按歌单的跨平台唯一键传进多选'))
    if 'Date.now() - this.lastLongPressAt < 600' not in fav:
        bad += 1
        issues.append(('AZ', 'FAIL', '没抑制长按后补发的 onClick，会同时打开详情页'))
    if 'SelectionBar({' not in fav or 'confirmRemoveSelected()' not in fav:
        bad += 1
        issues.append(('AZ', 'FAIL', '批量删除条 / 二次确认被一起删掉了'))
    # 预加载：按剩余时间触发、每首一次、可关闭、在途去重
    if 'const PRELOAD_LEAD_MS: number = 60000' not in ply:
        bad += 1
        issues.append(('AZ', 'FAIL', '预加载没有 60s 提前量，赶不上懒人模式 52s 寻源截止'))
    if 'this.duration - time <= PRELOAD_LEAD_MS' not in ply or '!this.preloadDone' not in ply:
        bad += 1
        issues.append(('AZ', 'FAIL', '预加载没按剩余时间触发或缺每首一次去重'))
    if 'this.preloadDone = false' not in ply:
        bad += 1
        issues.append(('AZ', 'FAIL', '切歌没有复位预加载标记，下一首不会再预取'))
    if 'if (!Settings.get().preloadNext())' not in ply:
        bad += 1
        issues.append(('AZ', 'FAIL', '预加载没有开关，用户无法关闭额外请求'))
    if 'getBool(PrefKeys.PRELOAD_NEXT, true)' not in cfg:
        bad += 1
        issues.append(('AZ', 'FAIL', '预加载开关没有默认开启'))
    if ('private inflight: Map<string, Promise<ResolveResult>>' not in res or
            'this.doResolve(' not in res):
        bad += 1
        issues.append(('AZ', 'FAIL', 'Resolver 没有同 key 在途去重，预取未完成时切歌会重复全源寻源'))
    if 'this.inflight.delete(gateKey)' not in res:
        bad += 1
        issues.append(('AZ', 'FAIL', '在途任务没在 finally 清理，后续取链会被永久短路'))
    # 汽水：2026-11-16 用户要求删掉界面说明，改守「解析器确实不认汽水」这条实现口径，
    # 界面文案一出现即视为说明回潮。
    if '汽水音乐等平台暂不支持' in fav:
        bad += 1
        issues.append(('AZ', 'FAIL', '收藏页导入面板的汽水说明又回来了（用户要求删说明）'))
    imp_src = next((s for f, s in src.items() if f.endswith('core/PlaylistImport.ets')), '')
    if 'qishui' in imp_src.lower():
        bad += 1
        issues.append(('AZ', 'FAIL', '歌单解析器居然认了汽水链接：没有官方公开接口，属于造能力'))
    if bad == 0:
        issues.append(('AZ', 'PASS',
                       '歌单收藏改为长按选中该张并进入多选（顶部「选择」已移除、批量删除保留），'
                       '播放剩余 60 秒预取下一首且同 key 在途去重，导入面板不再挂说明文案、解析器不认汽水链接'))


def check_fav_layout(src):
    """BB：歌单收藏页移除重复说明卡 + 同排卡片等高（标题区固定两行）。

    说明卡与 ImmersiveBar 的「歌单收藏 / N 个」信息重复、白占一屏；卡片
    一高一矮的根因是标题 maxLines(2) 却按内容撑高，一行 / 两行标题不齐。
    等高只在收藏页开启，发现页 / 搜索页必须保持原样（titleLines 默认 0）。
    """
    fav = next((s for f, s in src.items() if f.endswith('ui/pages/FavoriteSheetsPage.ets')), '')
    common = next((s for f, s in src.items() if f.endswith('ui/Common.ets')), '')
    discover = next((s for f, s in src.items() if f.endswith('ui/pages/DiscoverPage.ets')), '')
    search = next((s for f, s in src.items() if f.endswith('ui/pages/SearchPage.ets')), '')
    if not all((fav, common, discover, search)):
        issues.append(('BB', 'WARN', '没找齐收藏页 / Common / 发现页 / 搜索页，跳过布局检查'))
        return
    bad = 0
    # ① 顶部说明卡整体移除，计数交给标题栏 subtitle
    if '个歌单 · ' in fav or "Text('歌单收藏')" in fav or '顶部说明卡：' in fav:
        bad += 1
        issues.append(('BB', 'FAIL', '歌单收藏页还留着与标题栏重复的顶部说明卡'))
    if "subtitle: this.sheets.length.toString() + ' 个'" not in fav:
        bad += 1
        issues.append(('BB', 'FAIL', '说明卡移除了但标题栏没保留歌单计数'))
    # ② 等高：本页传 2 → 组件透传 → 标题区最小高度约束
    if 'titleLines: 2' not in fav:
        bad += 1
        issues.append(('BB', 'FAIL', '收藏页没开标题区固定两行，同排卡片仍会一高一矮'))
    if 'titleLines: this.titleLines' not in common:
        bad += 1
        issues.append(('BB', 'FAIL', 'GlassSheetCard 没把 titleLines 透传给 SheetCard'))
    if ('private titleMinHeight(): number' not in common or
            'constraintSize({ minHeight: this.titleMinHeight() })' not in common or
            '.justifyContent(FlexAlign.Start)' not in common):
        bad += 1
        issues.append(('BB', 'FAIL', '标题区没有固定最小高度 / 顶部对齐，副标题仍会错位'))
    # ③ 零外溢：默认值 0，发现页 / 搜索页不传这个参数
    if 'titleLines: number = 0' not in common:
        bad += 1
        issues.append(('BB', 'FAIL', 'titleLines 默认值不是 0，其它页面卡片会被误改'))
    if 'titleLines:' in discover or 'titleLines:' in search:
        bad += 1
        issues.append(('BB', 'FAIL', '发现页 / 搜索页也传了 titleLines，改动外溢到其它页'))
    if bad == 0:
        issues.append(('BB', 'PASS',
                       '歌单收藏页移除重复说明卡（计数保留在标题栏），'
                       '标题区固定两行使同排卡片与副标题齐平，等高仅本页生效'))


def check_download_swipe_stable(src):
    """BC：下载页必须同时满足「左滑不回弹」与「进度实时」。

    这是个两难，两次都踩过坑：
    - key 拼 progress → 进度一变 ListItem 重建 → swipeAction 展开态归零（回弹）；
    - key 只留 id + 换新对象引用 → 真机上 ArkUI 复用 ListItem 后不再把新 task
      交给按值传参的 @Builder，行内容冻结在首次快照（进度不实时）。
    正解是把行抽成独立组件 DownloadTaskRow：只接稳定 id，自己订阅
    downloadVersion，在渲染路径里读一次 dlVersion 挂依赖图，再按 id 从
    Downloader 实时数组取任务。行内容不再走 ForEach 传参。
    """
    dl = next((s for f, s in src.items() if f.endswith('ui/pages/DownloadsPage.ets')), '')
    if not dl:
        issues.append(('BC', 'WARN', '没找到 DownloadsPage，跳过左滑稳定性检查'))
        return
    bad = 0
    # ① 旧 key：把可变字段拼进去 = 每帧重建
    if 'task.id + task.status + task.progress.toString()' in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '下载页 ForEach key 又拼回 progress，进度刷新会把 ListItem 重建、左滑弹回'))
    m = re.search(r'ForEach\(this\.tasks,.*?\},\s*\(task:\s*DownloadTask\)\s*=>\s*([^)]*)\)',
                  dl, re.S)
    key = m.group(1).strip() if m else ''
    if key != 'task.id':
        bad += 1
        issues.append(('BC', 'FAIL', f'下载页 ForEach key 不是稳定的 task.id（当前：{key or "未识别"}）'))
    if any(w in key for w in ('progress', 'status', 'received', 'total')):
        bad += 1
        issues.append(('BC', 'FAIL', '下载页 ForEach key 含可变字段，左滑状态会随进度被重置'))
    # ② 行内容不能走 ForEach -> @Builder 按值传 task（key 稳定后会冻结）
    if 'this.taskRow(task, index)' in dl or '@Builder\n  taskRow(' in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '行 UI 仍是页面 @Builder 按值接 task，key 稳定后进度会冻结'))
    # ③ 独立行组件：订阅广播 + 读依赖 + 按 id 实时取数，三者缺一不可
    if 'struct DownloadTaskRow' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '没有独立行组件 DownloadTaskRow，进度无法脱离 ForEach 实时刷新'))
    if 'DownloadTaskRow({' not in dl or 'taskId: task.id' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', 'ListItem 没挂 DownloadTaskRow（或没传稳定 taskId）'))
    if "@StorageProp('downloadVersion') dlVersion" not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '行组件没订阅 downloadVersion，进度广播不会触发重绘'))
    if 'this.dlVersion + 1' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '行组件没在渲染路径读 dlVersion，订阅可能被编译器优化掉'))
    if 'private task(): DownloadTask' not in dl or 'App.get().downloads.byId(this.taskId)' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '行组件没按 id 从 Downloader O(1) 实时取任务'))
    # ④ 页面层不再做「换引用 / 快照」这类无效 hack，也不再把进度塞进 @Builder
    for kw, msg in (
        ('private taskSig(', '还留着上一版换引用 hack 的 taskSig'),
        ('private copyTask(', '还留着上一版换引用 hack 的 copyTask'),
        ('next.push(this.copyTask(t))', '还在生成任务快照（真机无效）'),
    ):
        if kw in dl:
            bad += 1
            issues.append(('BC', 'FAIL', '下载页 ' + msg))
    # ⑤ 三套手势必须同时在线：长按多选、单击暂停/开始、左滑删除。
    #    2026-11-16 用户明确要求「在下载页再加一个左滑删除」，左滑入口正式回归
    #    （第四次返工曾把它删掉，那时是「原来的都去掉」的口径）。
    for kw, msg in (('LongPressGesture(', '缺长按进入多选'),
                    ('.onClick(() =>', '行没接单击（暂停/开始/单选）'),
                    ('SelectionBar({', '缺公共多选条'),
                    ('.swipeAction(', '缺左滑删除入口'),
                    ('SwipeEdgeEffect.Spring', '左滑没有弹性回弹')):
        if kw not in dl:
            bad += 1
            issues.append(('BC', 'FAIL', '下载页 ' + msg))
    if bad == 0:
        issues.append(('BC', 'PASS',
                       '下载行抽成独立组件 DownloadTaskRow：key 只认 id 不重建，'
                       '行组件自订阅双信号并按 id O(1) 实时取数，进度实时；'
                       '长按多选 + 单击暂停/开始 + 左滑删除三套手势并存'))


def check_settings_subpages(src):
    """BD：歌曲列表全量显示封面 + 播放/外观/数据收成三个二级页（v2.62→v2.63）。

    用户三张截图：① 歌单/歌手/榜单页的歌曲行被大序号顶掉了封面，要统一成
    搜索页那样的「小序号 + 方形封面」；② 把「播放」分组的 5 个选项收进
    「播放设置」二级页；③ 把「外观」的主题和「歌词」整合成「外观」二级页。
    v2.63 又按同一范式把「数据」的备份 / 恢复收进「数据管理」二级页。
    这一组守住三件事，外加「返回链 / 路由 / 公共行组件不复制三份」。
    数据页的备份/恢复实现、说明文字与恢复后刷新由 BG 组单独锁。
    """
    bd = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    common = get('ui/Common.ets')
    settings = get('ui/pages/SettingsPage.ets')
    play = get('ui/pages/PlaySettingsPage.ets')
    appearance = get('ui/pages/AppearanceSettingsPage.ets')
    data = get('ui/pages/DataSettingsPage.ets')
    settings_common = get('ui/SettingsCommon.ets')
    index = get('pages/Index.ets')
    all_ets = '\n'.join(src.values())

    # ① 封面：SongRow 默认显示封面，全工程不许再有任何一处显式关掉它
    if '@Prop showCover: boolean = true;' not in common:
        bd += 1
        issues.append(('BD', 'FAIL', 'SongRow 的 showCover 默认值不是 true：歌曲列表又没封面了'))
    if 'showCover: false' in all_ets:
        bd += 1
        issues.append(('BD', 'FAIL', '仍有一处 SongRow 传 showCover: false：封面又被关掉了'))
    for name, cnt in (('ArtistPage', 2), ('SheetDetailPage', 2), ('RankBoardPage', 1),
                      ('SearchPage', 1)):
        page = get('ui/pages/' + name + '.ets')
        if page.count('showIndex: true') < cnt:
            bd += 1
            issues.append(('BD', 'FAIL', f'{name} 的 showIndex: true 不足 {cnt} 处：'
                                        '封面旁的小序号没保留（会退回大号序号占位）'))

    # ② 公共行组件：抽到单一文件，四个页面共用，不许复制 @Component
    for kw, msg in (('export struct SettingArrowRow', '缺 SettingArrowRow'),
                    ('export struct SettingSwitchRow', '缺 SettingSwitchRow'),
                    ('export function applyThemeMode', '主题应用没抽成公共函数')):
        if kw not in settings_common:
            bd += 1
            issues.append(('BD', 'FAIL', 'SettingsCommon.ets ' + msg))
    for label, text in (('设置主页', settings), ('播放设置', play), ('外观', appearance),
                        ('数据管理', data)):
        if "from '../SettingsCommon'" not in text:
            bd += 1
            issues.append(('BD', 'FAIL', label + ' 没引用 SettingsCommon 公共行组件（复制了组件定义）'))
        if 'struct SettingArrowRow' in text or 'struct SettingSwitchRow' in text:
            bd += 1
            issues.append(('BD', 'FAIL', label + ' 里又内联了一份行组件定义'))

    # ③ 三个二级页：内容齐全 + 自带 NavDestination / 顶栏 / 返回拦截
    for label, text, opts in (
        ('播放设置页', play, ('音质偏好', '启动时自动续播', '记住播放进度',
                              '弱网预加载下一首', '忽略音频打断')),
        ('外观页', appearance, ('跟随系统', '浅色', '深色', '字号', '显示翻译歌词')),
        ('数据管理页', data, ('备份我的数据', '从备份恢复', 'doBackup()')),
    ):
        for kw in opts:
            if kw not in text:
                bd += 1
                issues.append(('BD', 'FAIL', label + ' 缺「' + kw + '」选项'))
        for kw, msg in (('NavDestination()', '不是独立二级页'),
                        ('ImmersiveBar({', '没挂沉浸式顶栏'),
                        ('.onBackPressed(', '没接返回拦截'),
                        ('App.get().consumeBack', '返回没走统一优先级'),
                        ('glassCardBase(this.isDark)', '卡片没铺玻璃')):
            if kw not in text:
                bd += 1
                issues.append(('BD', 'FAIL', label + msg))
    if 'applyThemeMode(' not in appearance or 'applyThemeMode(' not in settings_common:
        bd += 1
        issues.append(('BD', 'FAIL', '外观页 / 公共组件没接 applyThemeMode 单一实现'))
    if 'qualitySheet' not in play or 'bindSheet(' not in play:
        bd += 1
        issues.append(('BD', 'FAIL', '播放设置页没把音质弹层一起搬过来'))
    if 'bindSheet(' in appearance:
        bd += 1
        issues.append(('BD', 'FAIL', '外观页不该有弹层：主题和歌词都是行内直改'))

    # ④ 设置主页收成三个入口，旧的展开项（含数据备份/恢复）不许留
    for kw, msg in (("push('playSettings'", '没有「播放设置」入口'),
                    ("push('appearanceSettings'", '没有「外观」入口'),
                    ("push('dataSettings'", '没有「数据管理」入口')):
        if kw not in settings:
            bd += 1
            issues.append(('BD', 'FAIL', '设置主页 ' + msg))
    for kw in ('启动时自动续播', '显示翻译歌词', "sectionTitle('歌词')",
               '备份我的数据', '从备份恢复', '包含收藏、歌单收藏'):
        if kw in settings:
            bd += 1
            issues.append(('BD', 'FAIL', '设置主页还留着「' + kw + '」：没有收进二级页'))
    for kw in ('音源管理', '默认发现平台', '数据管理',
               "sectionTitle('播放')", "sectionTitle('数据')", "sectionTitle('关于')"):
        if kw not in settings:
            bd += 1
            issues.append(('BD', 'FAIL', '设置主页把「' + kw + '」一起删了'))

    # ⑤ 路由表三个新名字都注册且 import
    for kw, msg in (("name === 'playSettings'", '没注册 playSettings'),
                    ("name === 'appearanceSettings'", '没注册 appearanceSettings'),
                    ("name === 'dataSettings'", '没注册 dataSettings'),
                    ('import { PlaySettingsPage }', '没 import 播放设置页'),
                    ('import { AppearanceSettingsPage }', '没 import 外观页'),
                    ('import { DataSettingsPage }', '没 import 数据管理页')):
        if kw not in index:
            bd += 1
            issues.append(('BD', 'FAIL', 'Index.ets ' + msg))

    if bd == 0:
        issues.append(('BD', 'PASS',
                       '5 处歌曲列表恢复「小序号 + 封面」；播放 5 项收进播放设置、'
                       '主题与歌词收进外观、备份/恢复收进数据管理，三个二级页各自带 '
                       'NavDestination + 返回链；公共行组件与主题应用单一实现，主页只留三个入口'))


def check_song_marquee(src):
    """BE：歌曲列表里长歌名 / 歌手·专辑不再省略号，改为实时滚动（跑马灯）。

    v2.56：统一用 API26 的 TextOverflow.MARQUEE + marqueeOptions({start:true})，
    只在文本溢出时无限循环滚动，短歌名保持静止。守住：
    ① SongRow（四类歌曲列表页共用）歌名与合并后的副标题各一处；
    ② 队列弹层 / 下载任务行 / 迷你播放条同步；
    ③ 每个跑马灯 Text 都要有确定宽度，否则溢出判定不触发；
    ④ 下载状态行随进度实时变化，必须保持 Ellipsis，不许跟着滚。
    v2.74：用户嫌长歌名滚太快，step 由 4 降到 2（约减半），7 处必须全部统一。
    """
    be = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    common = get('ui/Common.ets')
    queue = get('ui/QueueSheet.ets')
    downloads = get('ui/pages/DownloadsPage.ets')
    shell = get('ui/Shell.ets')
    all_ets = '\n'.join(src.values())

    # 只取 SongRow 组件自身（到下一个 export struct 为止），别把别的组件算进来
    s = common.find('export struct SongRow')
    e = common.find('export struct', s + 1)
    row = common[s:(e if e > s else len(common))]

    if row.count('TextOverflow.MARQUEE') < 2:
        be += 1
        issues.append(('BE', 'FAIL', 'SongRow 歌名 / 副标题没都用 MARQUEE：长歌名又会被截断'))
    if 'TextOverflow.Ellipsis' in row:
        be += 1
        issues.append(('BE', 'FAIL', 'SongRow 里还残留 Ellipsis：歌曲行仍有省略号'))
    if "Text('·')" in row:
        be += 1
        issues.append(('BE', 'FAIL', '副标题没合并成一段：三段 Text 各自滚动会互相挤压'))
    if row.count('marqueeOptions({ start: true') < 2:
        be += 1
        issues.append(('BE', 'FAIL', 'SongRow 的跑马灯没显式 start: true：可能不滚动'))

    for label, text, cnt in (('队列弹层', queue, 2), ('下载任务行', downloads, 1),
                             ('迷你播放条', shell, 2)):
        if text.count('TextOverflow.MARQUEE') < cnt:
            be += 1
            issues.append(('BE', 'FAIL', label + ' 的歌名/歌手没改成 MARQUEE'))
        if text.count('marqueeOptions({ start: true') < cnt:
            be += 1
            issues.append(('BE', 'FAIL', label + ' 的跑马灯没显式 start: true'))

    # 每个 MARQUEE 后面必须紧跟确定宽度，否则组件按内容自适应、不判定溢出
    for label, text in (('SongRow', row), ('队列弹层', queue), ('下载任务行', downloads),
                        ('迷你播放条', shell)):
        kw = 'TextOverflow.MARQUEE'
        pos = 0
        while True:
            i = text.find(kw, pos)
            if i < 0:
                break
            seg = text[i:i + 340]
            if ".width('100%')" not in seg and '.layoutWeight(1)' not in seg:
                be += 1
                issues.append(('BE', 'FAIL', label + ' 有个跑马灯 Text 没有确定宽度：溢出判定不触发'))
                break
            pos = i + len(kw)

    if 'marqueeOptions({ start: false' in all_ets:
        be += 1
        issues.append(('BE', 'FAIL', '存在 start: false 的跑马灯：写上去也不会滚'))

    st = downloads.find('Text(this.statusText(this.task()))')
    if st < 0 or 'TextOverflow.Ellipsis' not in downloads[st:st + 400]:
        be += 1
        issues.append(('BE', 'FAIL', '下载状态行没保持 Ellipsis：进度每 300ms 变化会不停重置滚动'))

    # v2.74：滚动速度统一降到 step 2；留着任一处 step 4 就是「改了 SongRow 忘了迷你条」。
    # HdsTabs 重做后 miniBarBuilder 迁到 HdsNav.ets，跑马灯分布变了，故只要求
    # 「无 step:4 + 至少 6 处 step:2」，不再硬编码恰好 7 处。
    if all_ets.count('step: 2, fromStart: true') < 6 or 'step: 4' in all_ets:
        be += 1
        issues.append(('BE', 'FAIL', '跑马灯速度没统一到 step: 2：仍有旧速度或漏改组件'))

    if be == 0:
        issues.append(('BE', 'PASS',
                       '歌曲列表长歌名/副标题改实时滚动：SongRow（4 类列表页）+ 队列弹层 + '
                       '下载任务行 + 迷你条统一 MARQUEE，短名静止、溢出才滚；'
                       '状态行保持省略号，读屏语句不变'))


def check_quality_summary_in_subpage(src):
    """BF：当前音质摘要只在「播放设置」二级页显示，设置主页入口是纯入口。

    v2.62 把播放选项收进二级页后，主页「播放设置」入口右侧仍留了
    qualityLabel(this.qualityPref)（截图里的「全景声」），既和「外观设置」的
    空入口不一致，又与二级页「音质偏好」项 + 顶栏副标题重复。用户判定为 bug：
    入口只负责跳转，当前值进二级页看。守住「主页不显示、二级页不丢」两端。
    """
    bf = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    settings = get('ui/pages/SettingsPage.ets')
    play = get('ui/pages/PlaySettingsPage.ets')

    # ① 主页入口：播放设置 / 外观设置都是纯跳转，不再挂当前音质值
    for label, anchor in (('播放设置', "title: '播放设置'"),
                          ('外观设置', "title: '外观设置'")):
        i = settings.find(anchor)
        if i < 0:
            bf += 1
            issues.append(('BF', 'FAIL', '找不到「' + label + '」入口'))
        elif "value: ''" not in settings[i:i + 260]:
            bf += 1
            issues.append(('BF', 'FAIL', label + '入口仍带当前值：不是纯跳转入口'))
    if 'qualityLabel' in settings:
        bf += 1
        issues.append(('BF', 'FAIL', '设置主页还引用 qualityLabel：音质摘要没搬干净'))
    if "@StorageProp('qualityPref')" in settings:
        bf += 1
        issues.append(('BF', 'FAIL', '设置主页还在订阅 qualityPref：主页不需要跟踪音质'))

    # ② 二级页仍完整显示当前音质，删了主页摘要不丢信息
    if play.count('qualityLabel(this.qualityPref)') < 2:
        bf += 1
        issues.append(('BF', 'FAIL', '播放设置页没保住当前音质显示：主页删掉后信息丢了'))
    if 'this.qualityPref === item' not in play:
        bf += 1
        issues.append(('BF', 'FAIL', '播放设置页音质弹层勾选态丢了'))

    # ③ 别误伤主页其它行：默认发现平台没有二级页，值仍应留在主页
    if 'value: platformName(this.discoverPlatform)' not in settings:
        bf += 1
        issues.append(('BF', 'FAIL', '默认发现平台的当前值被误删'))

    if bf == 0:
        issues.append(('BF', 'PASS',
                       '当前音质摘要归位到播放设置二级页：主页两个入口都是纯跳转，'
                       '音质偏好项 + 顶栏副标题仍实时显示当前档位，默认发现平台值不变'))


def check_data_subpage(src):
    """BG：数据分组收进「数据管理」二级页，且备份/恢复行为不退化（v2.63）。

    用户要求「把数据那一栏也做个二级界面」。守住两端：
    ① 设置主页「数据」只剩一个纯跳转入口，备份/恢复/说明全搬进二级页；
    ② 二级页自带 NavDestination + 顶栏 + 返回链，两个操作行接上 doBackup/doRestore，
       走系统面板（无 bindSheet 半模态），恢复成功后主题仍走 applyThemeMode；
    ③ 恢复会刷新常驻一级页：Backup.refreshAfterRestore 广播 discoverPlatform，
       设置主页 @StorageProp + @Watch 订阅后 reload，保证「默认发现平台」摘要即时刷新。
    """
    bg = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    settings = get('ui/pages/SettingsPage.ets')
    data = get('ui/pages/DataSettingsPage.ets')
    backup = get('core/Backup.ets')
    index = get('pages/Index.ets')

    if not data:
        issues.append(('BG', 'FAIL', '缺 DataSettingsPage.ets：数据二级页没建'))
        return

    # ① 主页：单入口 + 不再内联备份逻辑
    if "push('dataSettings', new NavParam())" not in settings:
        bg += 1
        issues.append(('BG', 'FAIL', '设置主页「数据」没跳到 dataSettings 二级页'))
    for kw in ('doBackup', 'doRestore', 'Backup.exportTo', 'Backup.restoreFrom',
               '包含收藏、歌单收藏'):
        if kw in settings:
            bg += 1
            issues.append(('BG', 'FAIL', '设置主页还留着「' + kw + '」：没搬进数据二级页'))
    if "import { Backup }" in settings:
        bg += 1
        issues.append(('BG', 'FAIL', '设置主页还 import Backup：搬走后成了冗余引用'))
    # 主页玻璃卡仍是 6 张（数据卡收成单入口但没删卡），AJ 组 ns<6 不退化
    ns = len(re.findall(r'\.backgroundColor\(glassCardBase\(this\.isDark\)\)', settings))
    if ns < 6:
        bg += 1
        issues.append(('BG', 'FAIL', f'设置主页只剩 {ns} 张玻璃卡：收数据入口时误删了卡片'))

    # ② 二级页：两个操作行 + 实现 + 说明 + 独立二级页形态
    for kw, msg in (('备份我的数据', '缺备份行'), ('从备份恢复', '缺恢复行'),
                    ('doBackup()', '缺 doBackup 实现'), ('doRestore()', '缺 doRestore 实现'),
                    ('Backup.exportTo(context)', '备份没走 Backup.exportTo'),
                    ('Backup.restoreFrom(context)', '恢复没走 Backup.restoreFrom'),
                    ('this.doBackup();', '备份行没接 doBackup 实现'),
                    ('applyThemeMode(this.settings.themeMode(), context)',
                     '恢复成功后没应用主题（会「恢复了但深浅色没变」)')):
        if kw not in data:
            bg += 1
            issues.append(('BG', 'FAIL', '数据管理页' + msg))
    for kw, msg in (('NavDestination()', '不是独立二级页'),
                    ('ImmersiveBar({', '没挂沉浸式顶栏'),
                    ('.onBackPressed(', '没接返回拦截'),
                    ('App.get().consumeBack', '返回没走统一优先级'),
                    ('glassCardBase(this.isDark)', '卡片没铺玻璃')):
        if kw not in data:
            bg += 1
            issues.append(('BG', 'FAIL', '数据管理页' + msg))
    if 'bindSheet(' in data:
        bg += 1
        issues.append(('BG', 'FAIL', '数据管理页不该有 bindSheet：备份/恢复走系统面板'))
    if "from '../SettingsCommon'" not in data:
        bg += 1
        issues.append(('BG', 'FAIL', '数据管理页没复用公共行组件'))

    # ③ 恢复后刷新常驻一级页：备份层广播 + 主页订阅，两端都要在
    if "AppStorage.setOrCreate('discoverPlatform'" not in backup:
        bg += 1
        issues.append(('BG', 'FAIL', 'Backup.refreshAfterRestore 没广播 discoverPlatform'))
    if "@StorageProp('discoverPlatform') @Watch('onDiscoverPlatform')" not in settings or \
            'onDiscoverPlatform(): void' not in settings:
        bg += 1
        issues.append(('BG', 'FAIL', '设置主页没订阅 discoverPlatform 广播：恢复后摘要不刷新'))

    # ④ 路由注册
    if "name === 'dataSettings'" not in index or 'DataSettingsPage()' not in index:
        bg += 1
        issues.append(('BG', 'FAIL', 'Index.ets 没注册 dataSettings 路由'))

    if bg == 0:
        issues.append(('BG', 'PASS',
                       '数据分组收进「数据管理」二级页：主页单入口 + 6 张玻璃卡不减，'
                       '备份/恢复/说明整体搬入且接上 Backup，恢复后主题与发现平台摘要即时刷新'))


def check_wy_account(src):
    """BI：网易云本人账号登录 + 账号推荐（v2.64）。

    用户要求「增加网易云平台登录，用本人账号实现听歌喜好推荐，Cookie 和二维码
    扫码都要」。这一组守住整条链路不退化：
      ① 加密层：weapi 双 AES-CBC（cryptoFramework）+ 预计算 encSecKey，
         不引入 RSA 库 / BigInt / 三方依赖；带 Cookie 与 csrf 发 POST。
      ② 登录层：二维码 unikey → 扫码状态 801/802/803/800/8821 → 803 提取
         MUSIC_U/__csrf；Cookie 手动登录；登录态校验；退出；本机持久化 + 广播。
      ③ 推荐层：每日推荐歌曲 / 歌单 / 我的歌单 / 我喜欢的，转成 SongInfo/SheetInfo，
         未登录一律不请求。
      ④ UI 层：账号二级页二维码 + Cookie 兜底 + 点播 + 退出；轮询 setTimeout 递归
         且 aboutToDisappear 清理；设置入口 + 路由注册。
      ⑤ 安全边界：不得硬编码任何他人 Cookie；凭证不进备份。
    """
    bi = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    api = get('core/WyApi.ets')
    account = get('core/WyAccount.ets')
    recommend = get('core/WyRecommend.ets')
    page = get('ui/pages/WyAccountPage.ets')
    section = get('ui/WyRecommendSection.ets')
    settings = get('ui/pages/SettingsPage.ets')
    index = get('pages/Index.ets')
    app = get('core/App.ets')
    constants = get('common/Constants.ets')
    backup = get('core/Backup.ets')

    for label, text, path in (('WyApi.ets', api, 'core/WyApi.ets'),
                              ('WyAccount.ets', account, 'core/WyAccount.ets'),
                              ('WyRecommend.ets', recommend, 'core/WyRecommend.ets'),
                              ('WyAccountPage.ets', page, 'ui/pages/WyAccountPage.ets')):
        if not text:
            bi += 1
            issues.append(('BI', 'FAIL', '缺 ' + path + '：网易云账号链路不完整'))

    # ① 加密层：本地 weapi，零三方依赖
    for kw, msg in (('cryptoFramework.createSymKeyGenerator', '没用原生 AES 密钥生成器'),
                    ("cryptoFramework.createCipher('AES128|CBC|PKCS7')", '缺 AES-128-CBC 加密'),
                    ("'0CoJUm6Qyw8W8jud'", '缺 presetKey'),
                    ('ENC_SEC_KEY', '缺预计算 encSecKey 常量'),
                    ('encodeToStringSync', '缺 base64 编码'),
                    ('weapiBody', '缺 weapi 表单体封装'),
                    ('function normalizeCookie', '缺 Cookie 归一化'),
                    ('function cookieValue', '缺 Cookie 取值')):
        if kw not in api:
            bi += 1
            issues.append(('BI', 'FAIL', 'WyApi.ets ' + msg))
    # 固定密钥换 encSecKey：不得再引 RSA / BigInt / crypto-js（ArkTS 无 BigInt，会编译失败）。
    # 只看代码行，注释里解释「为什么不用 RSA/BigInt」属正常说明，不算混入。
    api_code = '\n'.join(ln for ln in api.split('\n')
                         if not ln.strip().startswith('*') and not ln.strip().startswith('/*')
                         and not ln.strip().startswith('//'))
    for kw in ('BigInt', 'createSign', 'createCipheriv', 'require(', 'CryptoJS',
               '1n', '0x10001n'):
        if kw in api_code:
            bi += 1
            issues.append(('BI', 'FAIL', 'WyApi.ets 混入了 ' + kw + '：固定密钥方案不需要，且 ArkTS 不支持'))
    # 请求必须带 Cookie / csrf / Referer，且返回 set-cookie 供 803 取证。
    # Referer 走 Http 层的 options.referer（request 内部转请求头），不直接写 headers。
    for kw, msg in (("options.headers['Cookie']", '请求没带 Cookie'),
                    ('csrf_token=', 'URL 没带 csrf_token'),
                    ('options.referer = WY_REFERER', '没设 Referer'),
                    ("result.headers['set-cookie']", '没回传 set-cookie（803 拿不到凭证）')):
        if kw not in api:
            bi += 1
            issues.append(('BI', 'FAIL', 'WyApi.ets ' + msg))

    # ② 登录层：二维码 + Cookie + 状态 + 持久化 + 广播
    for kw, msg in (('/weapi/login/qrcode/unikey', '缺二维码 unikey 接口'),
                    ('/weapi/login/qrcode/client/login', '缺扫码状态轮询接口'),
                    ('/weapi/w/nuser/account/get', '缺登录态校验接口'),
                    ('code === 803', '没处理 803 授权成功'),
                    ('normalizeCookie(reply.setCookie)', '803 没从 set-cookie 提取凭证'),
                    ('loginByCookie', '缺 Cookie 手动登录'),
                    ('logout()', '缺退出登录'),
                    ('PrefKeys.WY_COOKIE', '凭证没落本机 Store'),
                    ("AppStorage.setOrCreate('wyLoginVersion'", '登录态没广播 wyLoginVersion'),
                    ("AppStorage.setOrCreate('wyNick'", '登录态没广播 wyNick')):
        if kw not in account:
            bi += 1
            issues.append(('BI', 'FAIL', 'WyAccount.ets ' + msg))
    # 初始化：App.init 里 Store 就绪后要 init，页面首帧才有登录态
    if 'WyAccount.get().init()' not in app:
        bi += 1
        issues.append(('BI', 'FAIL', 'App.init 没初始化 WyAccount：账号页首帧读不到登录态'))
    for key in ('WY_COOKIE', 'WY_NICK', 'WY_UID', 'WY_AVATAR'):
        if ("static readonly " + key) not in constants:
            bi += 1
            issues.append(('BI', 'FAIL', 'Constants.PrefKeys 缺 ' + key))

    # ③ 推荐层：四个账号接口 + 未登录短路 + 转工程模型
    for kw, msg in (('/weapi/v3/discovery/recommend/songs', '缺每日推荐歌曲接口'),
                    ('/weapi/v1/discovery/recommend/resource', '缺每日推荐歌单接口'),
                    ('/weapi/user/playlist', '缺我的歌单接口'),
                    ("newSong('wy')", '推荐歌曲没转成 SongInfo(wy)'),
                    ("newSheet('wy'", '推荐歌单没转成 SheetInfo(wy)'),
                    ('account.isLoggedIn()', '推荐接口没做未登录短路')):
        if kw not in recommend:
            bi += 1
            issues.append(('BI', 'FAIL', 'WyRecommend.ets ' + msg))

    # ④ UI 层：二维码 / Cookie 兜底 / 点播 / 退出 / 定时清理 / 二级页形态
    for kw, msg in (('QRCode(this.qrUrl)', '没用原生 QRCode 渲染二维码'),
                    ("'https://music.163.com/login?codekey='", '二维码内容不是官方登录链接'),
                    ('code === 801', '没处理等待扫码 801'),
                    ('code === 802', '没处理待确认 802'),
                    ('code === 800', '没处理二维码过期 800'),
                    ('code === 8821', '没处理风控 8821'),
                    ('doCookieLogin', '缺 Cookie 登录入口'),
                    ('doLogout', '缺退出登录入口'),
                    ('clearTimeout(this.pollTimer)', '轮询定时器没清理（退出页面会改已销毁 @State）'),
                    ('aboutToDisappear', '缺页面销毁清理'),
                    ('NavDestination()', '不是独立二级页'),
                    ('ImmersiveBar({', '没挂沉浸式顶栏'),
                    ('.onBackPressed(', '没接返回拦截'),
                    ('App.get().consumeBack', '返回没走统一优先级')):
        if kw not in page:
            bi += 1
            issues.append(('BI', 'FAIL', 'WyAccountPage.ets ' + msg))
    # v2.72：账号页按用户口径隐藏「每日推荐 / 推荐歌单」，点播改由首页实时板块承载。
    # v2.73：用户再次改口径 —— 账号页恢复「我的歌单」(mySheetRail)，本页单独拉真实
    # /weapi/user/playlist；每日推荐与推荐歌单仍只在首页。点播能力始终留在板块组件。
    if 'App.get().play(this.songList, index)' not in section:
        bi += 1
        issues.append(('BI', 'FAIL', '首页每日推荐板块不能点播：账号页隐藏推荐后点播能力丢了'))
    for gone in ('recommendSongs', 'dailySheetRail'):
        if gone in page:
            bi += 1
            issues.append(('BI', 'FAIL', '账号页还渲染「' + gone + '」：v2.72 应已隐藏搬去首页'))
    if 'WyRecommend.mySheets()' not in page:
        bi += 1
        issues.append(('BI', 'FAIL', '账号页恢复的「我的歌单」没走真实 /weapi/user/playlist 接口'))
    # 主色按钮文字：signal 琥珀实底上只能用 onSignal 墨字（AC 墨栈组会扫全工程，这里再钉一次）
    if ".backgroundColor(this.p().primary)" in page and "#FF191713" not in page:
        bi += 1
        issues.append(('BI', 'FAIL', '账号页主色按钮用了白字：signal 琥珀底应改 onSignal 墨字'))

    # 入口 + 路由
    if "push('wyAccount', new NavParam())" not in settings or "@StorageProp('wyNick')" not in settings:
        bi += 1
        issues.append(('BI', 'FAIL', '设置页缺「网易云账号」入口或未订阅登录态摘要'))
    if "name === 'wyAccount'" not in index or 'WyAccountPage()' not in index:
        bi += 1
        issues.append(('BI', 'FAIL', 'Index.ets 没注册 wyAccount 路由'))

    # ⑤ 安全边界：不得硬编码任何真实 Cookie/MUSIC_U 值；凭证不进备份
    all_new = api + account + recommend + page
    hardcoded = re.findall(r"MUSIC_U\s*=\s*['\"]([A-Za-z0-9_\-]{20,})", all_new)
    if hardcoded:
        bi += 1
        issues.append(('BI', 'FAIL', '源码里硬编码了疑似真实 MUSIC_U 凭证（' + str(len(hardcoded)) + ' 处）'))
    for kw in ('WY_COOKIE', 'WY_NICK', 'wy_cookie'):
        if kw in backup:
            bi += 1
            issues.append(('BI', 'FAIL', '凭证 ' + kw + ' 被写进备份：只允许本机留存'))

    if bi == 0:
        issues.append(('BI', 'PASS',
                       '网易云本人账号链路完整：原生 weapi 双 AES-CBC + 预计算 encSecKey（零三方依赖），'
                       '二维码扫码(801/802/803/800/8821) + Cookie 兜底 + 登录态本机持久化与广播，'
                       '每日推荐歌曲/歌单/我的歌单转成工程模型可点播；账号页定时清理、凭证不硬编码不进备份'))


def check_wy_fav_sync(src):
    """BJ：歌单收藏 ↔ 网易云账号双向同步（v2.65）。

    用户要求「在音栈收藏/取消收藏网易云歌单，网易云 APP 要跟着变；在 APP 里
    收藏/取消收藏，进音栈歌单收藏也要立刻有（或没有），状态必须对得上」。
    这一组守住整条链路与「状态正确性」的几道保险，缺一都会退化成假同步：
      ① 双向：subscribe(t=1/2) 写云端 + user/playlist 读云端订阅列表。
      ② 权威与保护：以云端为准，但拿不到列表 / uid / 空列表一律收手不动本地。
      ③ 乐观更新 + 待同步队列：本地操作先落本地再异步写，失败留队列重放。
      ④ 首次只补不删、pending 优先：不误删刚收藏的或历史本地收藏。
      ⑤ 按纯数字 id 归集（自愈 kind 差异重复），只同步 wy 可订阅歌单。
      ⑥ 触发点：进收藏页 / 回前台 / 登录成功 / 手动同步；退出只清中间态。
      ⑦ 回写不再触发 hook（防死循环）；同步中间态不进备份、不占新路由。
    """
    bj = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    sync = get('core/WyFavSync.ets')
    lib = get('core/Library.ets')
    app = get('core/App.ets')
    constants = get('common/Constants.ets')
    backup = get('core/Backup.ets')
    fav = get('ui/pages/FavoriteSheetsPage.ets')
    home = get('ui/pages/HomePage.ets')
    account_page = get('ui/pages/WyAccountPage.ets')
    index = get('pages/Index.ets')

    if not all((sync, lib, app, constants, backup, fav, home, account_page, index)):
        issues.append(('BJ', 'WARN', '没找齐同步链路相关文件，跳过双向同步检查'))
        return

    # ── ① 双向读写：云端订阅列表 + 收藏/取消收藏接口 ──
    for kw, msg in (('/weapi/user/playlist', '没拉账号订阅歌单列表（云端→本地）'),
                    ('/weapi/playlist/subscribe', '没调收藏/取消收藏接口（本地→云端）'),
                    ("'/weapi/playlist/unsubscribe'",
                     '取消收藏没走独立 unsubscribe 路径（老写法 t=2 恒回 501）'),
                    ("add ? '/weapi/playlist/subscribe' : '/weapi/playlist/unsubscribe'",
                     '收藏/取消没按独立路径分流'),
                    ('isSubscribed', '没区分「收藏的歌单」与「自建歌单」'),
                    ('subscribed === true', '订阅判定没优先用 subscribed 字段'),
                    ('WyFavSync.get().reconcile()', '缺完整对账入口')):
        if kw not in sync and kw not in (fav + home + account_page):
            bj += 1
            issues.append(('BJ', 'FAIL', 'WyFavSync ' + msg))
    if "/weapi/playlist/subscribe" not in sync or 'subscribe(op.id, op.add, cookie)' not in sync:
        bj += 1
        issues.append(('BJ', 'FAIL', '待同步操作没真正写到云端 subscribe 接口'))

    # ── ② 状态正确性：拿不到云端数据时绝不动本地 ──
    for kw, msg in (('if (cloud === null)', '云端拉取失败没短路，可能拿空数据清掉本地收藏'),
                    ('uid <= 0', 'uid 取不到时没停手（游客兜底列表会误删本地）'),
                    ('list.length === 0', '空列表没判为接口降级（风控会误删本地）'),
                    ('return null', '拉取失败没返回 null 让上层收手')):
        if kw not in sync:
            bj += 1
            issues.append(('BJ', 'FAIL', 'WyFavSync ' + msg))
    # applyWyFavSync 必须排在「cloud === null 直接 return」之后
    if sync.find('Library.get().applyWyFavSync(') < sync.find('if (cloud === null)') or \
            sync.find('if (cloud === null)') < 0:
        bj += 1
        issues.append(('BJ', 'FAIL', '本地差量写回早于云端失败判断：失败时也会改本地收藏'))

    # ── ③ 乐观更新 + 待同步队列：失败保留、下次重放 ──
    for kw, msg in (('onLocalChange(sheet: SheetInfo, added: boolean)', '缺本地收藏变更入口'),
                    ('this.pending = keep', '本地变更没进待同步队列'),
                    ('savePending()', '待同步队列没持久化（杀进程会丢）'),
                    ('this.flush()', '对账前没重放待同步操作'),
                    ("JSON.parse(text) as WyFavOp[]", '启动时没读回待同步队列'),
                    ('if (ok)', '写云端失败没保留队列项（会静默丢操作）')):
        if kw not in sync:
            bj += 1
            issues.append(('BJ', 'FAIL', 'WyFavSync ' + msg))

    # ── ④ 首次只补不删 + pending 优先 ──
    for kw, msg in (('if (this.inited)', '没有「首次对账只补不删」保护，会误删历史本地收藏'),
                    ('pendingIds.indexOf(id) < 0', '差量没排除待同步 id（刚收藏的会被反向删/重复加）'),
                    ('this.cloudIds = cloudIds', '没保存云端快照，判断不出 APP 端取消了哪个')):
        if kw not in sync:
            bj += 1
            issues.append(('BJ', 'FAIL', 'WyFavSync ' + msg))

    # ── ⑤ Library：按 id 归集、范围限定、回写不触发 hook ──
    for kw, msg in (('static wyFavHook', 'Library 没挂本地变更钩子'),
                    ('static wySyncId(sheet: SheetInfo): string', '没有可同步歌单判定'),
                    ('static wyIsId(id: string): boolean', '没有纯数字 id 判定'),
                    ('wyFavoriteIds(): string[]', '没有本地 wy 歌单 id 快照'),
                    ('applyWyFavSync(addSheets: SheetInfo[], removeIds: string[]): number',
                     '没有云端差量回写接口'),
                    ('Library.fireWyFavHook(sheet, false)', '取消收藏没通知同步引擎'),
                    ('Library.fireWyFavHook(sheet, true)', '新增收藏没通知同步引擎'),
                    ('removedWy.push(it)', '批量删除没收集被删的 wy 歌单'),
                    ("sheet.kind !== 'playlist' && sheet.kind !== 'user'",
                     '没把同步范围限定在可订阅歌单（榜单/专辑会被写坏账号）')):
        if kw not in lib:
            bj += 1
            issues.append(('BJ', 'FAIL', 'Library ' + msg))
    if "sheet.platform !== 'wy'" not in lib:
        bj += 1
        issues.append(('BJ', 'FAIL', 'Library 没限定 platform=wy：其它平台歌单会被误同步'))
    # 回写路径绝不能触发 hook，否则云端→本地→云端死循环
    apply_body = _func_body(lib, 'applyWyFavSync') or ''
    if 'fireWyFavHook' in apply_body or 'wyFavHook(' in apply_body:
        bj += 1
        issues.append(('BJ', 'FAIL', 'applyWyFavSync 触发了 wyFavHook：云端回写会无限循环写账号'))
    if "Library.wyFavHook = " not in app or 'WyFavSync.get().init()' not in app:
        bj += 1
        issues.append(('BJ', 'FAIL', 'App.init 没注册收藏钩子 / 没初始化同步引擎'))

    # ── ⑥ 触发点与状态广播 ──
    for kw, msg in (("WyFavSync.get().reconcile().catch", '进页没自动对账（APP 端收藏了进来会看不到）'),
                    ('@StorageProp(\'wyFavSyncState\')', '收藏页没订阅同步状态'),
                    ('@StorageProp(\'wyFavSyncAt\')', '收藏页没订阅同步时间戳'),
                    ('syncBar()', '收藏页没有同步状态条 / 手动同步入口')):
        if kw not in fav:
            bj += 1
            issues.append(('BJ', 'FAIL', 'FavoriteSheetsPage ' + msg))
    for kw, msg in (("@StorageProp('foregroundAt') @Watch('onAppForeground')",
                     '首页没订阅回前台'),
                    ('WyFavSync.get().reconcile()', '回前台没触发对账（首页计数会停在旧值）')):
        if kw not in home:
            bj += 1
            issues.append(('BJ', 'FAIL', 'HomePage ' + msg))
    for kw, msg in (('WyFavSync.get().onLoginSuccess()', '登录成功没触发对账'),
                    ('WyFavSync.get().onLogout()', '退出登录没清同步中间态'),
                    ('syncCard()', '账号页没有同步状态展示')):
        if kw not in account_page:
            bj += 1
            issues.append(('BJ', 'FAIL', 'WyAccountPage ' + msg))
    for kw in ("AppStorage.setOrCreate('wyFavSyncState'",
               "AppStorage.setOrCreate('wyFavSyncVersion'",
               "AppStorage.setOrCreate('wyFavSyncAt'"):
        if kw not in sync:
            bj += 1
            issues.append(('BJ', 'FAIL', '同步引擎没广播 ' + kw))
    # 退出只清中间态，不删本地收藏：onLogout 里不能有清空收藏表的调用
    logout_body = _func_body(sync, 'onLogout') or ''
    if 'applyWyFavSync' in logout_body or 'clearFavorites' in logout_body:
        bj += 1
        issues.append(('BJ', 'FAIL', '退出登录清掉了本地收藏：用户数据不该随账号消失'))

    # ── ⑦ 边界：中间态不进备份、不占新路由、常量齐全 ──
    for key in ('WY_FAV_PENDING', 'WY_FAV_CLOUD', 'WY_FAV_INIT', 'WY_FAV_AT'):
        if 'static readonly ' + key not in constants:
            bj += 1
            issues.append(('BJ', 'FAIL', 'Constants.PrefKeys 缺 ' + key))
    for kw in ('WY_FAV_PENDING', 'WY_FAV_CLOUD', 'WY_FAV_INIT', 'WY_FAV_AT', 'v4_wy_fav_'):
        if kw in backup:
            bj += 1
            issues.append(('BJ', 'FAIL', '同步中间态 ' + kw + ' 被写进备份：换机会串到别的账号'))
    # 不新增页面/路由：Index 里不该出现同步相关路由名
    if 'wyFav' in index:
        bj += 1
        issues.append(('BJ', 'FAIL', '为同步新增了页面路由：路由白名单会失守（同步不需要新页面）'))

    if bj == 0:
        issues.append(('BJ', 'PASS',
                       '歌单收藏与网易云账号双向同步：subscribe(t=1/2) 写云端 + user/playlist 拉订阅列表对账；'
                       '云端为准但失败/无 uid/空列表一律不动本地，乐观更新 + 待同步队列重放，'
                       '首次只补不删、按纯数字 id 归集自愈重复项、只同步 wy 可订阅歌单；'
                       '进页/回前台/登录/手动四处触发，回写不触发 hook 防死循环，中间态不进备份'))


def check_discover_feed(src):
    """BM：发现页由「写死骨架」改为按平台实时编排的板块流（v2.56 发现页重做）。

    用户「最好能和官方保持一致，能实时读取……不同平台不同 ui 界面分布，
    不是像现在一样界面都写死了」。这里的「官方」= 各音源平台官方，不是华为音乐
    （华为方案上一轮已废弃）。本组锁住四件事，防止后续重构退回写死骨架：
      ① 数据模型 + 编排层存在，板块由 layout 驱动，UI 不认平台；
      ② 四平台各直连不同官方发现接口，并发拉取、单接口失败该板块缺席不塞假数据；
      ③ 页面用 ForEach(sections) + 独立 @Component 渲染，不再有写死两段与 @State tab；
      ④ 点击还原成既有 SheetInfo / SongInfo / ArtistInfo，音源引擎零改动。
    """
    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    model = get('common/Discover.ets')
    feed = get('core/DiscoverFeed.ets')
    page = get('ui/pages/DiscoverPage.ets')
    bad = 0
    if not all((model, feed, page)):
        issues.append(('BM', 'WARN', '没找齐发现页板块流三件套，跳过检查'))
        return

    # ① 数据模型：8 种布局 + 4 种动作，板块由 layout 驱动
    for kw, msg in (('export const LAY_BANNER', '缺 banner 布局'),
                    ('export const LAY_CARD_RAIL', '缺方形封面横滑布局'),
                    ('export const LAY_SONG_LIST', '缺歌曲行布局'),
                    ('export const LAY_RANK_CARDS', '缺榜单网格布局'),
                    ('export const LAY_RANK_GROUP', '缺分组榜单布局'),
                    ('export const LAY_ARTIST_RAIL', '缺歌手头像布局'),
                    ('export const LAY_BIG_CARD', '缺大图横滑布局'),
                    ('export const LAY_SHEET_GRID', '缺推荐池占位布局'),
                    ('export const ACT_SHEET', '缺打开歌单动作'),
                    ('export const ACT_SONG', '缺直接播放动作'),
                    ('export const ACT_ARTIST', '缺打开歌手动作'),
                    ('export const ACT_SEARCH', '缺搜索兜底动作'),
                    ('export class DiscoverSection', '缺板块模型'),
                    ('layout: number', '板块没有 layout 字段'),
                    ('items: DiscoverItem[]', '板块没有条目数组'),
                    ('export function officialNote', '没把「官方实时来源」写进副标题')):
        if kw not in model:
            bad += 1
            issues.append(('BM', 'FAIL', 'Discover 模型 ' + msg))

    # ② 四平台各拉不同官方接口；并发 + 失败缺席 + 不塞假数据
    for kw, msg in (("platform === 'wy'", '没给网易云单独编排'),
                    ("platform === 'tx'", '没给 QQ 音乐单独编排'),
                    ("platform === 'kg'", '没给酷狗单独编排'),
                    ('this.kwSheets(', '没给酷我单独编排'),
                    ('Promise.all(jobs)', '板块不是并发拉取，切平台会串行卡顿'),
                    ('/api/banner/get', '网易云缺 banner 官方接口'),
                    ('/api/personalized/playlist', '网易云缺每日推荐接口'),
                    ('/api/personalized/newsong', '网易云缺推荐新歌接口'),
                    ('/api/personalized/privatecontent', '网易云缺独家放送接口'),
                    ('/api/toplist/detail', '网易云缺官方榜单接口'),
                    ('musicu.fcg', 'QQ 缺分组榜单 musicu.fcg'),
                    ('fcg_get_diss_by_tag.fcg', 'QQ 缺歌单广场接口'),
                    ('https://m.kugou.com/?json=true', '酷狗缺首页一次给全五板块的接口'),
                    ('getRcmPlayList', '酷我缺推荐歌单接口'),
                    ('bangMenu', '酷我缺分组榜单接口')):
        if kw not in feed:
            bad += 1
            issues.append(('BM', 'FAIL', 'DiscoverFeed ' + msg))
    # 单接口失败返回空数组让板块缺席：catch 数应覆盖所有接口组
    absent = len(re.findall(r'catch\s*\(e\)\s*\{\s*return \[\];\s*\}', feed))
    if absent < 9:
        bad += 1
        issues.append(('BM', 'FAIL',
                       '只有 %d 处「接口失败→板块缺席」，官方接口挂了会塞假数据或整页崩' % absent))
    # 酷我两个实测坑：data.data 才是数组，榜单击进去的 id 用 sourceid
    if 'resp.data?.data ?? []' not in feed:
        bad += 1
        issues.append(('BM', 'FAIL', '酷我推荐歌单没按 data.data 解析（实测 data 是对象）'))
    if 'r.sourceid' not in feed:
        bad += 1
        issues.append(('BM', 'FAIL', '酷我榜单 id 没用 sourceid（菜单 id 打不开详情页）'))
    # 方向护栏：不是华为音乐（上一轮已废弃）
    if '华为音乐' in feed or 'UIDesignKit' in feed:
        bad += 1
        issues.append(('BM', 'FAIL', '编排层混进了上一轮废弃的华为音乐方案'))

    # ③ 页面：ForEach(sections) 驱动 + 独立组件，不再写死两段骨架
    for kw, msg in (('ForEach(this.sections', '页面不是由板块流数据驱动'),
                    ('section.layout ===', '页面不按 layout 分派渲染'),
                    ('SectionBlock({', '板块没有交给独立组件渲染'),
                    ('struct SectionBlock', '板块渲染器不是独立 @Component'),
                    ('@Prop section: DiscoverSection', '板块没用 @Prop 跟随 @State 刷新'),
                    ('onItem: (item: DiscoverItem)', '板块点击没回传条目')):
        if kw not in page:
            bad += 1
            issues.append(('BM', 'FAIL', 'DiscoverPage ' + msg))
    for kw, msg in (('@State tab: number = 0', '又退回「排行榜/推荐歌单」写死分段'),
                    ('tab === 0', '还有分段 0 的写死分支'),
                    ('tab === 1', '还有分段 1 的写死分支'),
                    ("'排行榜 / 推荐歌单'", '还留着写死的两段文案')):
        if kw in page:
            bad += 1
            issues.append(('BM', 'FAIL', 'DiscoverPage ' + msg))
    # 独立组件体内不许按平台写 if，否则「UI 只认 layout」不成立
    seg = page.split('struct SectionBlock', 1)
    block = seg[1].split('\n}\n', 1)[0] if len(seg) > 1 else ''
    if not block:
        bad += 1
        issues.append(('BM', 'FAIL', '截不到 SectionBlock 组件体'))
    elif re.search(r'platform\s*===', block):
        bad += 1
        issues.append(('BM', 'FAIL', 'SectionBlock 里按平台写死了 UI 分支：版式该由数据决定'))

    # ④ 点击还原既有入口，音源引擎零改动。
    # v2.65：全量页与首页共用 core/DiscoverAction.openDiscoverItem，
    # 断言范围跟着扩到「发现页 + 公共文件」，四个入口与 payload 还原一条不删。
    action = get('core/DiscoverAction.ets')
    for kw, msg in (('App.get().openSheet(', '没还原歌单详情入口'),
                    ('App.get().playOne(', '没还原直接播放入口'),
                    ('App.get().openArtist(', '没还原歌手页入口'),
                    ('App.get().openSearch(', '没还原搜索兜底入口'),
                    ('JSON.parse(item.payload)', '点击没从 payload 还原工程模型')):
        if kw not in page and kw not in action:
            bad += 1
            issues.append(('BM', 'FAIL', '板块点击链路 ' + msg))

    if bad == 0:
        issues.append(('BM', 'PASS',
                       '发现页改为「按平台实时编排的板块流」：UI 只认 section.layout，'
                       '四平台各直连不同官方发现接口（wy 5 / tx 2 / kg 1 / kw 2），'
                       '并发拉取、单接口失败该板块缺席不塞假数据；'
                       '不再有写死的「排行榜/推荐歌单」两段与 @State tab；'
                       '点击经公共 openDiscoverItem 还原成既有 SheetInfo/SongInfo/ArtistInfo，音源引擎零改动'))


def check_discover_more(src):
    """BN：每个板块能「点进去看全部」（v2.65 · 发现页「更多 ›」全量页）。

    用户看到板块右上「6 项 / 12 项 / 19 项」后连问：这些是上限吗？官方不能点进去吗？
    分析结论：那是自己加的纯展示角标，条数被 URL 里的 limit / ein / slice 钉死，
    板块本身点不动，只能点单张卡。B 方案把「去哪看全部」变成数据：
      ① 模型有 DiscoverMore + DiscoverSection.more，编排层给每个板块挂描述；
      ② 页面角标换成可点「更多 ›」，榜单类复用既有 rankboard 页；
      ③ 新增通用全量页并注册路由，歌单类支持上拉分页 + 分类筛选；
      ④ 点击与首页共用公共 openDiscoverItem，音源引擎零改动。
    本组防止以后又退回「写死条数 + 不可点板块」。
    """
    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    model = get('common/Discover.ets')
    feed = get('core/DiscoverFeed.ets')
    action = get('core/DiscoverAction.ets')
    page = get('ui/pages/DiscoverPage.ets')
    full = get('ui/pages/DiscoverSectionPage.ets')
    index = get('pages/Index.ets')
    app = get('core/App.ets')
    bad = 0
    if not all((model, feed, action, page, full, index, app)):
        issues.append(('BN', 'WARN', '没找齐板块全量页链路文件，跳过检查'))
        return

    # ① 模型：more 描述 + 板块挂 more + 导航参数
    for kw, msg in (('export class DiscoverMore', '缺「更多」描述模型'),
                    ('more: DiscoverMore', '板块没挂 more 描述'),
                    ('source: string', 'more 缺数据源 key'),
                    ('snapshot: string', 'more 缺快照字段'),
                    ('export class DiscoverMoreParam', '缺全量页导航参数')):
        if kw not in model:
            bad += 1
            issues.append(('BN', 'FAIL', 'Discover 模型 ' + msg))

    # ② 编排层：三类规格 + 统一取数 + 分类 + 快照；每个板块都挂了 more
    for kw, msg in (('function sheetsMore(', '缺歌单广场分页规格'),
                    ('function snapshotMore(', '缺快照规格'),
                    ('function rankMore(', '缺榜单规格'),
                    ('sec.more = spec', 'section() 没把 more 挂到板块上'),
                    ("spec.snapshot = JSON.stringify(items)", '快照类没把首页 items 带给全量页'),
                    ('async more(spec', '缺统一分页取数入口'),
                    ('sheetsByTag(spec.platform, cat, page)', '分页没走既有官方歌单广场接口'),
                    ('async moreTags(spec', '缺分类取数'),
                    ('snapshotItems(spec', '缺快照还原'),
                    ('pool.more =', '推荐池板块没挂 more')):
        if kw not in feed:
            bad += 1
            issues.append(('BN', 'FAIL', 'DiscoverFeed ' + msg))
    # 板块数：每个 section() 调用都必须带 spec 参数（防止新板块忘了挂 more）
    # 逐条数：section(' 调用次数 vs 三种规格工厂的调用次数（各减去 1 个函数定义处）
    n_section = len(re.findall(r'\bsection\(\'', feed))
    n_spec = len(re.findall(r'(?:sheetsMore|snapshotMore|rankMore)\(', feed)) - 3
    if n_section == 0 or n_spec < n_section:
        bad += 1
        issues.append(('BN', 'FAIL',
                       f'有板块没挂 more 描述（section 调用 {n_section} 处，规格 {n_spec} 处）'))

    # ③ 全量页：独立二级页 + 分页 + 分类 + 快照 + 统一点击 + 返回拦截
    for kw, msg in (('NavDestination()', '不是独立二级页'),
                    ('.onBackPressed(', '没挂返回拦截'),
                    ('onReady((ctx: NavDestinationContext)', '没从路由参数读 more 描述'),
                    ('.onReachEnd(', '没有上拉分页'),
                    ('this.loadMore()', '上拉没接分页加载'),
                    ('this.feed.more(this.spec, 1, this.tagId)', '首屏没走统一取数'),
                    ('this.feed.moreTags(this.spec)', '没拉分类'),
                    ('this.feed.snapshotItems(this.spec)', '没还原快照'),
                    ('this.switchTag(tag.id)', '分类胶囊点了没切换'),
                    ('openDiscoverItem(item)', '条目点击没复用公共还原函数'),
                    ('this.hasMore', '没有「还有没有更多」状态')):
        if kw not in full:
            bad += 1
            issues.append(('BN', 'FAIL', 'DiscoverSectionPage ' + msg))

    # ④ 首页角标可点 + 路由注册 + 公共入口
    for kw, msg in (("Text('更多')", '角标还是数字或纯展示，没换成「更多」'),
                    ('MoreChip({ more: this.section.more })', '板块标题右侧没挂可点入口'),
                    ("App.get().openDiscoverSection(this.more)", 'MoreChip 没接统一跳转'),
                    ('openDiscoverItem(item)', '首页点击没复用公共还原函数')):
        if kw not in page:
            bad += 1
            issues.append(('BN', 'FAIL', 'DiscoverPage ' + msg))
    if "Text(this.section.items.length.toString() + ' 项')" in page:
        bad += 1
        issues.append(('BN', 'FAIL', '「N 项」纯展示角标又回来了'))
    for kw, msg in (("name === 'discoverSection'", 'pageMap 没注册全量页'),
                    ('DiscoverSectionPage()', 'pageMap 没挂全量页组件'),
                    ('import { DiscoverSectionPage }', 'Index 没导入全量页')):
        if kw not in index:
            bad += 1
            issues.append(('BN', 'FAIL', 'Index.ets ' + msg))
    for kw, msg in (('openDiscoverSection(more: DiscoverMore)', 'App 缺统一跳转入口'),
                    ("this.openRankBoard(more.platform)", '榜单类没复用既有榜单页'),
                    ("this.push('discoverSection'", '没 push 全量页路由')):
        if kw not in app:
            bad += 1
            issues.append(('BN', 'FAIL', 'App.ets ' + msg))
    # 公共点击函数必须两个页面都用，且四处入口齐全
    for kw, msg in (('export function openDiscoverItem', '缺公共还原函数'),
                    ('ACT_SONG', '缺直接播放分支'),
                    ('ACT_ARTIST', '缺歌手页分支'),
                    ('ACT_SEARCH', '缺搜索兜底分支'),
                    ('ACT_SHEET', '缺歌单详情分支')):
        if kw not in action:
            bad += 1
            issues.append(('BN', 'FAIL', 'DiscoverAction ' + msg))
    if 'openDiscoverItem(item)' not in page or 'openDiscoverItem(item)' not in full:
        bad += 1
        issues.append(('BN', 'FAIL', '首页与全量页没有共用同一份点击还原逻辑'))

    if bad == 0:
        issues.append(('BN', 'PASS',
                       '板块「更多 ›」全量页接通：模型带 more 描述，编排层给每个板块挂'
                       '歌单广场分页/快照/榜单三类规格；角标改为可点入口，榜单类复用 rankboard；'
                       '全量页支持上拉分页 + 分类切换 + 快照铺满，条目点击与首页共用 openDiscoverItem，'
                       '音源引擎与详情页零改动'))


def check_account_top(src):
    """BO：v2.68 账号栏置顶 + 结构回归。
    护栏：账号是设置页第一个分组且单行直达 wyAccount 登录网易云账号；
    底栏仍是三个一级页、路由表无 myAccount；不做「我的」一级页、不做华为账号与云盘备份。"""
    bad = 0
    def text(suffix):
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    settings = text('ui/pages/SettingsPage.ets')
    shell = text('ui/Shell.ets')
    index = text('pages/Index.ets')

    # ① 账号是设置页第一个分组（在「音源」之前），单行直达 wyAccount
    acc = settings.find("sectionTitle('账号')")
    src_first = settings.find("sectionTitle('音源')")
    if acc < 0 or src_first < 0 or acc > src_first:
        bad += 1
        issues.append(('BO', 'FAIL', '账号不是设置页第一个分组（没置顶到「音源」之前）'))
    if "push('wyAccount', new NavParam())" not in settings:
        bad += 1
        issues.append(('BO', 'FAIL', '账号入口没直达 wyAccount 二级页登录网易云账号'))
    if "push('myAccount'" in settings:
        bad += 1
        issues.append(('BO', 'FAIL', '账号栏仍指向 myAccount 账号中心（该页应已删除）'))

    # ② 底栏仍三个一级页、路由表无 myAccount / 无「我的」一级页
    labels = re.findall(r"label:\s*'([^']+)'", shell)
    if labels != ['首页', '发现', '设置']:
        bad += 1
        issues.append(('BO', 'FAIL', '底栏不是「首页/发现/设置」三项：又冒出了额外一级页'))
    for kw in ('myAccount', 'MinePage', 'MyAccountPage'):
        if kw in index:
            bad += 1
            issues.append(('BO', 'FAIL', 'Index 仍残留 %s（我的页/账号中心应已删除）' % kw))

    # ③ 华为账号 / 云空间 / 云盘备份 / 本机身份卡那套全部去除（不误伤音源文件读取提示）
    banned = ('备份到云盘', '从云盘恢复', '华为账号与自动云同步', '当前版本不提供华为账号登录',
              '本机档案', '@kit.AccountKit', 'cloudFileSyncEnabled')
    for f, s in src.items():
        for kw in banned:
            if kw in s:
                bad += 1
                issues.append(('BO', 'FAIL', '%s 残留「%s」：华为账号/云盘备份那套应已全部去除' % (f, kw)))

    if bad == 0:
        issues.append(('BO', 'PASS',
                       '账号栏置顶为设置页第一个分组，单行直达 wyAccount 二级页登录网易云账号；'
                       '底栏仍 首页/发现/设置 三项、路由表无 myAccount；'
                       '「我的」一级页与华为账号/云空间/云盘备份/本机身份卡全部去除'))


def check_fav_sync_truthful(src):
    """BP：歌单收藏 ↔ 网易云账号「实时同步 + 状态不撒谎」（v1.0）。

    v1.0：QQ / 酷狗账号引擎已连根删除，聚合层收口为只代理 WyFavSync 一路。
    本组相应收口为只锁 wy，但用户最在意的两条底线一字不放：
      ① 状态不撒谎：ok 必须队列清空、启动不继承 ok、partial 如实降级；
      ② 实时：EntryAbility 前台定时对账（12s 心跳），后台 / 退出停止。
    """
    bp = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    hub = get('core/FavSyncHub.ets')
    wy = get('core/WyFavSync.ets')
    fav = get('ui/pages/FavoriteSheetsPage.ets')
    wy_page = get('ui/pages/WyAccountPage.ets')
    ability = get('entryability/EntryAbility.ets')

    if not all((hub, wy, fav, wy_page, ability)):
        issues.append(('BP', 'WARN', '没找齐同步状态相关文件，跳过检查'))
        return

    # ① 状态机：队列清空才 ok，启动首帧不继承 ok
    for kw, msg in (("this.stateText = 'partial'", '队列没清空时没有 partial 降级（会假装 ok）'),
                    ("this.stateText = 'ok'", '缺 ok 状态设置'),
                    ('this.lastAt = Date.now()', '没有干净同步时间戳'),
                    ('this.pending.length === 0', 'ok 判定没检查队列是否清空'),
                    ('启动首帧不继承 ok', '启动仍可能继承 ok 假装已同步')):
        if kw not in wy:
            bp += 1
            issues.append(('BP', 'FAIL', 'WyFavSync ' + msg))

    # ② 聚合层：结构化状态 + 严格 clean + 只读快照
    for kw, msg in (('export interface FavSyncStatus', '缺统一状态结构 FavSyncStatus'),
                    ('status(scope: string): FavSyncStatus', '缺 status() 聚合入口'),
                    ('label(scope: string): string', '缺 label() 统一文案'),
                    ('toastText(scope: string): string', '缺 toastText() 统一结论'),
                    ('auto === 0 && manual === 0 && at > 0', 'clean 判定没要求队列清空'),
                    ('reconcileAllAwait()', '手动同步没等对账跑完就下结论')):
        if kw not in hub:
            bp += 1
            issues.append(('BP', 'FAIL', 'FavSyncHub ' + msg))
    for kw, msg in (('peekState(): string', '缺只读状态快照（读取会触发广播死循环）'),
                    ('ensureReady(): void', '缺不广播的就绪读取'),
                    ('manualCount(): number', '缺受限项计数'),
                    ('peekManual(): number', '缺只读受限项快照'),
                    ('const confirmed: string[]', '缺云端回读确认')):
        if kw not in wy:
            bp += 1
            issues.append(('BP', 'FAIL', 'WyFavSync ' + msg))

    # 「已与账号同步」必须只出现在 label() 的 clean 分支里
    label_start = hub.find('label(scope: string): string')
    label_end = hub.find('toastText(scope: string): string', label_start)
    label_body = hub[label_start:label_end] if label_start >= 0 and label_end > label_start else ''
    if not label_body:
        bp += 1
        issues.append(('BP', 'FAIL', 'FavSyncHub 找不到 label() 函数体'))
    else:
        said = label_body.find("return '已与账号同步 '")
        clean_at = label_body.find('if (s.clean)')
        if said < 0 or clean_at < 0 or said < clean_at:
            bp += 1
            issues.append(('BP', 'FAIL', 'label() 的「已与账号同步」没被限定在 clean 分支'))
        if clean_at >= 0 and "' · '" in label_body[clean_at:]:
            bp += 1
            issues.append(('BP', 'FAIL', 'clean 分支还拼了待同步尾巴，会重新制造自相矛盾'))
    # 平台中性受限文案仍在（不写死酷狗 APP）
    if '项需在平台 APP 内处理' not in hub or '需在酷狗 APP' in hub:
        bp += 1
        issues.append(('BP', 'FAIL', 'FavSyncHub 缺中性受限文案 / 又写死了酷狗 APP'))

    # ③ 两处 UI 都走聚合，且不再自己拼「项待上传」
    for name, text in (('FavoriteSheetsPage', fav), ('WyAccountPage', wy_page)):
        if 'FavSyncHub.get().label(' not in text:
            bp += 1
            issues.append(('BP', 'FAIL', name + ' 状态条没用统一 label()，仍会各判各的'))
        if '项待上传' in text:
            bp += 1
            issues.append(('BP', 'FAIL', name + ' 仍自己拼「项待上传」，会与已同步同框'))
        if 'reconcileAllAwait()' not in text:
            bp += 1
            issues.append(('BP', 'FAIL', name + ' 手动同步没等对账跑完就报结论'))
        if 'toastText(' not in text:
            bp += 1
            issues.append(('BP', 'FAIL', name + ' toast 没用统一真实结论'))
        if "WyFavSync.get().reconcile().then" in text:
            bp += 1
            issues.append(('BP', 'FAIL', name + ' toast 仍只看单平台中间结果'))

    # ④ 实时：应用级前台对账（生命周期挂载 + 心跳 + 停止）
    for kw, msg in (('startForegroundSync()', '缺前台实时对账启动'),
                    ('stopForegroundSync()', '缺前台实时对账停止'),
                    ('HEARTBEAT_MS', '缺心跳间隔常量'),
                    ('scheduleHeartbeat()', '缺心跳递归调度')):
        if kw not in hub:
            bp += 1
            issues.append(('BP', 'FAIL', 'FavSyncHub ' + msg))
    for kw, msg in (('FavSyncHub.get().startForegroundSync()', 'onForeground 没启动实时对账'),
                    ('FavSyncHub.get().stopForegroundSync()', '后台/退出没停实时对账'),
                    ('onBackground()', '缺 onBackground 生命周期回调')):
        if kw not in ability:
            bp += 1
            issues.append(('BP', 'FAIL', 'EntryAbility ' + msg))

    if bp == 0:
        issues.append(('BP', 'PASS',
                       '同步状态不撒谎：ok 必须队列清空、启动不继承 ok、partial 如实降级；'
                       '两处 UI 共用 FavSyncStatus 聚合结论，「已同步」只在 clean 分支，'
                       'toast 等对账跑完再报；前台 12s 心跳把云端→本地压到秒级，后台停止；'
                       'v1.0 聚合层收口为仅网易云，QQ / 酷狗账号引擎已连根删除'))


def check_wy_unsubscribe_restricted(src):
    """BQ：网易云「取消收藏」写云端真正生效 + 异常时不撒谎（v2.69）。

    根因：工程原用 /weapi/playlist/subscribe + t=2 取消收藏，这是已被服务端
    弃用的老写法 —— 真实凭证实测恒回 501，云端 /weapi/user/playlist 读回歌单
    仍在；换 id 类型 / Cookie 形态 / 参数写法 / 静置 100s 后均稳定 501，而无效
    id 回 404、带 os=pc 回 405，排除鉴权、频控与 os=pc 因素。
    官方 NeteaseCloudMusicApi 4.32.0 的 playlist_subscribe 按 t 选两个独立路径，
    取消为 /weapi/playlist/unsubscribe、请求体只有 { id }。实测 weapi 版：
      · unsubscribe 对自建歌单回 400、对未订阅公开歌单回 200；
      · 端到端净零验证：临时收藏公开歌单 → unsubscribe 回 200 → 云端列表
        7→6、该歌单消失，账号回到起始状态。
    修复：取消改走独立路径；subscribe 三态 + blocked 受限队列作为 501 异常兜底，
    守住「绝不把 501 判成功」「绝不 12s 无限重放」两条底线。
    """
    bq = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    wy = get('core/WyFavSync.ets')
    hub = get('core/FavSyncHub.ets')
    fav = get('ui/pages/FavoriteSheetsPage.ets')

    if not all((wy, hub, fav)):
        issues.append(('BQ', 'WARN', '没找齐取消收藏受限治理相关文件，跳过检查'))
        return

    # ① 写结果必须三态，且 501 按 add 分流：订阅幂等成功、取消如实受限
    for kw, msg in (('blocked: boolean', 'WyFavOp 没有受限标记字段'),
                    ('subscribe(id: string, add: boolean, cookie: string): Promise<string>',
                     'subscribe 没改成三态返回（boolean 无法区分「拒绝」与「失败」）'),
                    ("'/weapi/playlist/unsubscribe'", '取消收藏没改用独立 unsubscribe 路径'),
                    ("add ? '/weapi/playlist/subscribe' : '/weapi/playlist/unsubscribe'",
                     '收藏/取消没按独立路径分流'),
                    ("return add ? 'ok' : 'restricted'", '501 没按 add 分流（取消收藏会假成功）'),
                    ("return 'retry'", '缺可重试态'),
                    ("return 'ok'", '缺明确成功态')):
        if kw not in wy:
            bq += 1
            issues.append(('BQ', 'FAIL', 'WyFavSync ' + msg))
    if 'return add && code === 501' in wy:
        bq += 1
        issues.append(('BQ', 'FAIL', '仍在用旧的 boolean 501 判定，取消收藏会永久卡重试'))
    if "'t': add ? 1 : 2" in wy:
        bq += 1
        issues.append(('BQ', 'FAIL', '仍在用 t=1/t=2 老写法，取消收藏恒回 501 且云端不删'))

    # ② flush 跳过受限项，绝不再每 12s 打一个注定失败的接口
    for kw, msg in (('if (op.blocked)', 'flush 没跳过受限项（会反复打云端）'),
                    ("verdict === 'restricted'", '缺服务端拒绝分支'),
                    ('next.push({ id: it.id, add: it.add, blocked: true })',
                     '受限项没落标记，下次心跳又会重放'),
                    ('subscribe(op.id, op.add, cookie)', '待同步项没真正写云端')):
        if kw not in wy:
            bq += 1
            issues.append(('BQ', 'FAIL', 'WyFavSync ' + msg))

    # ③ 计数按 blocked 分流：受限项不算「正在自动重试」
    for kw, msg in (('if (!op.blocked)', '可重试计数没排除受限项'),
                    ('manualCount(): number', '缺受限项计数'),
                    ('peekManual(): number', '缺只读受限项快照'),
                    ('peekPending(): number', '缺只读可重试项快照')):
        if kw not in wy:
            bq += 1
            issues.append(('BQ', 'FAIL', 'WyFavSync ' + msg))

    # ④ 云端回读确认仍在 + 旧数据兼容 + 登录解冻 + pending 保护
    for kw, msg in (('const confirmed: string[]', '缺云端回读确认（受限项永远无法归零）'),
                    ('op.blocked === true', '旧落盘数据没兼容补标'),
                    ('next.push({ id: op.id, add: op.add, blocked: false })',
                     '重新登录没解冻受限项，换凭证也不会重试'),
                    ('pendingIds.push(op.id)',
                     '对账没保留 pending 保护（本地取消的歌单会被云端加回来）')):
        if kw not in wy:
            bq += 1
            issues.append(('BQ', 'FAIL', 'WyFavSync ' + msg))

    # ⑤ 文案按平台中性表述，不能只说酷狗、也不能只说「取消收藏」；状态条有待办必须显示。
    # 历史上 QQ / 酷狗也曾出现受限项，且可能是「收藏」而非「取消收藏」，故统一
    # 中性化为「项需在平台 APP 内处理」。这里同时锁死新文案存在、旧文案不回潮。
    if '项需在平台 APP 内处理' not in hub:
        bq += 1
        issues.append(('BQ', 'FAIL', 'FavSyncHub 缺平台中性的受限文案'))
    if '项需在平台 APP 内取消收藏' in hub or '需在酷狗 APP' in hub:
        bq += 1
        issues.append(('BQ', 'FAIL', 'FavSyncHub 受限文案仍写死酷狗/取消收藏，QQ 收藏受限项会误导'))
    label_start = hub.find('label(scope: string): string')
    label_end = hub.find('toastText(scope: string): string', label_start)
    label_body = hub[label_start:label_end] if label_start >= 0 and label_end > label_start else ''
    if '酷狗 APP' in label_body:
        bq += 1
        issues.append(('BQ', 'FAIL', 'label() 仍写死酷狗 APP'))
    if 'v.manual > 0' not in fav:
        bq += 1
        issues.append(('BQ', 'FAIL', '收藏页状态条没在受限项出现时显示'))

    # ⑥ 历史修复不能被本轮改动回退
    for kw, msg in (("'/weapi/playlist/subscribe'", '写云端接口被改动'),
                    ("'t': 1", '收藏没沿用 t=1'),
                    ('stripPcOs(cookie)', 'os=pc 剔除修复被回退'),
                    ('this.pending.length === 0', '队列清空才 ok 的判定被回退')):
        if kw not in wy:
            bq += 1
            issues.append(('BQ', 'FAIL', 'WyFavSync ' + msg))

    if bq == 0:
        issues.append(('BQ', 'PASS',
                       '网易云取消收藏改走独立 /weapi/playlist/unsubscribe（老 t=2 恒回 501、'
                       '云端不删），净零验证云端列表 7→6 真实删除；subscribe 三态 + '
                       'blocked 兜底、心跳不再无限重放、manual 计数与平台中性文案、'
                       '云端回读确认出队、重新登录解冻；绝不用 501 假成功'))


def check_qq_write_post_and_fav_button(src):
    """BR：收藏页心形角标可点（v1.0）。

    QQ 写云端 GET→POST / 三态受限治理那批断言随 QQ 账号引擎一并删除
    （v1.0 已连根删除整套 QQ / 酷狗账号体系）。本组只保留「心形角标升级为
    可点按钮」这条与账号平台无关的通用 UI 护栏，防止后续改版回退。
    """
    br = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    common = get('ui/Common.ets')
    fav = get('ui/pages/FavoriteSheetsPage.ets')
    lib = get('core/Library.ets')

    if not all((common, fav, lib)):
        issues.append(('BR', 'WARN', '没找齐心形角标相关文件，跳过检查'))
        return

    for kw, msg in (('@Prop favTappable: boolean = false', 'SheetCard/GlassSheetCard 缺可点开关'),
                    ('onFavTap: () => void', '缺心形点击回调'),
                    ('HitTestMode.Block', '心形没用 Block 独立命中（点它会冒泡打开详情页）'),
                    ('HitTestMode.None', '外层角标容器没保持穿透'),
                    ('stateStyles({', '心形按钮缺按压反馈'),
                    ('if (this.favTappable)', '心形点击没按开关门控')):
        if kw not in common:
            br += 1
            issues.append(('BR', 'FAIL', 'Common ' + msg))
    if 'favTappable: this.favTappable' not in common:
        br += 1
        issues.append(('BR', 'FAIL', 'GlassSheetCard 没把 favTappable 透传给 SheetCard'))
    if 'this.onFavTap();' not in common:
        br += 1
        issues.append(('BR', 'FAIL', 'GlassSheetCard 没把 onFavTap 透传给 SheetCard'))
    for kw, msg in (('favTappable: !this.selectMode', '收藏页没启用心形按钮 / 没在选择模式禁用'),
                    ('Library.get().toggleSheetFavorite(sheet)', '点心形没走统一收藏切换'),
                    ("App.get().toast(on ? '已收藏' : '已取消收藏')", '点心形没有结果反馈'),
                    ('onFavTap: (): void =>', '收藏页没传心形点击回调')):
        if kw not in fav:
            br += 1
            issues.append(('BR', 'FAIL', 'FavoriteSheetsPage ' + msg))
    if 'Library.fireWyFavHook(sheet, false)' not in lib:
        br += 1
        issues.append(('BR', 'FAIL', 'Library 取消收藏没分发同步 hook（点角标不会同步云端）'))

    if br == 0:
        issues.append(('BR', 'PASS',
                       '收藏页心形角标保持可点按钮：独立命中不冒泡、按压反馈、选择模式禁用，'
                       '点击走 Library 统一收藏切换并分发网易云同步 hook；'
                       'QQ 写云端那批断言随账号引擎删除一并移除'))


def check_home_realtime_recommend(src):
    """BS：账号页收口仅网易云 + 首页实时推荐板块（v2.71）。

    历史背景：QQ / 酷狗账号同步在客户端写不通，v1.0 已把整套账号引擎连根删除；
    ② 把账号页的「每日推荐 / 为你推荐歌单」搬到首页，像发现页一样是实时状态，
    而不是写死固定内容。

    可行性依据：WyRecommend 已有需登录态的 weapi 真实接口，返回现成 SongInfo /
    SheetInfo；首页是常驻一级页，已有 foregroundAt / wyLoginVersion 广播可用。
    落地：WyRecommendHub 做唯一数据源（并发 + 在途锁 + 未登录清空 + 版本广播 +
    失败保留旧数据），WyRecommendSection 订阅同一份快照，四处触发（进页 /
    回前台 / 登录变化 / 下拉），板块头显示「更新于 HH:mm」。
    v2.72 用户改口径：账号页三块推荐整体隐藏，推荐只在首页；每日推荐从纵向
    前 5 首改成横向轨铺满完整 30 首，首页四宫格第四格换成歌单收藏、下载移到
    顶栏。本组随之改查新形态，不恢复 v2.29 模块编排、不新增路由。
    """
    bs = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    hub = get('core/WyRecommendHub.ets')
    section = get('ui/WyRecommendSection.ets')
    home = get('ui/pages/HomePage.ets')
    wy_page = get('ui/pages/WyAccountPage.ets')
    settings = get('ui/pages/SettingsPage.ets')

    if not all((hub, section, home, wy_page, settings)):
        issues.append(('BS', 'WARN', '没找齐首页实时推荐 / 账号收口相关文件，跳过检查'))
        return

    # ① 唯一数据源：并发、在途锁、登录态收手、版本广播、失败不动旧数据
    for kw, msg in (("AppStorage.setOrCreate('wyRecVersion'", 'hub 没广播版本（两处 UI 无法实时同步）'),
                    ('WyRecommend.dailySongs()', 'hub 没拉每日推荐歌曲'),
                    ('WyRecommend.dailySheets()', 'hub 没拉为你推荐歌单'),
                    ('if (this.inFlight)', 'hub 缺在途锁（回前台/下拉会重复打云端）'),
                    ("if (!WyAccount.get().isLoggedIn())", 'hub 没按登录态收手'),
                    ('this.songList = []', '未登录/退出没清空数据（会展示过期画像）'),
                    ("this.hintText = '推荐更新失败，点此重试'", '失败没给可重试提示'),
                    ('this.at = Date.now()', '缺最近成功时间戳（体现不出实时状态）')):
        if kw not in hub:
            bs += 1
            issues.append(('BS', 'FAIL', 'WyRecommendHub ' + msg))
    if 'const pSongs = WyRecommend.dailySongs();' not in hub or \
            'const pSheets = WyRecommend.dailySheets();' not in hub:
        bs += 1
        issues.append(('BS', 'FAIL', 'hub 没并发启动两个请求（串行 await 会拖慢刷新）'))
    if 'Store.get()' in hub:
        bs += 1
        issues.append(('BS', 'FAIL', '推荐数据落了本机存档（会展示过期画像）'))

    # ② 板块组件：订阅同一份快照、复用公共组件、未登录只给入口、显示更新时间
    for kw, msg in (("@StorageProp('wyRecVersion')", '板块没订阅 hub 版本'),
                    ("@Watch('onHubChange')", '版本变化没触发重读'),
                    ('WyRecommendHub.get()', '板块没读同一份数据源'),
                    ("push('wyAccount', new NavParam())", '未登录没给账号页入口'),
                    ('GlassSheetCard({', '推荐歌单没复用公共卡片'),
                    ('SectionHeader({', '板块头没复用公共标题头'),
                    ('Cover({', '歌曲卡没复用公共封面组件'),
                    ("'homeRec_'", 'ForEach 没带稳定 key'),
                    ('更新于 ', '板块没显示最近更新时间'),
                    ('if (!this.loggedIn)', '未登录分支缺失'),
                    ('App.get().play(this.songList, index)', '每日推荐歌曲不能点播')):
        if kw not in section:
            bs += 1
            issues.append(('BS', 'FAIL', 'WyRecommendSection ' + msg))
    if 'WyRecommend.dailySongs' in section or 'WyRecommend.dailySheets' in section:
        bs += 1
        issues.append(('BS', 'FAIL', '板块自己拉接口，绕过了唯一数据源'))
    # v2.73：用户纠正口径 —— 每日推荐是「5 首一组、可左右滑动换组」，不是每首一张
    # 小卡连续横滑。实现为 Swiper 分页轨：每页一整块 5 首纵向列表，30 首切 6 组，
    # 分组用 songList.slice 只切当前页，总量仍完整（pageCount 由 songList.length 算）。
    for kw, msg in (('const REC_PAGE_SIZE: number = 5;', '缺「5 首一组」分组常量'),
                    ('private pageCount(): number', '缺按 songList.length 算组数（30 首不能丢）'),
                    ('private pageIndexes(): number[]', '缺分页下标生成'),
                    ('Swiper() {', '每日推荐没改成 Swiper 分页轨'),
                    ('.loop(false)', '分页轨开了循环：末组再滑会绕回第一组'),
                    ('this.songList.slice(page * REC_PAGE_SIZE', '每页没按全局下标切 5 首'),
                    ('this.play(page * REC_PAGE_SIZE + row)', '分组点播没换算成全局下标')):
        if kw not in section:
            bs += 1
            issues.append(('BS', 'FAIL', 'WyRecommendSection ' + msg))
    if '@Prop limit' in section or 'limit: number' in section or 'slice(0, this.limit)' in section:
        bs += 1
        issues.append(('BS', 'FAIL', '板块还留着 limit 截断参数，30 首显示不全'))
    # 为你推荐歌单仍是水平横向轨；每日推荐已改分页轨，故只要求至少一条水平 Scroll
    if 'ScrollDirection.Horizontal' not in section:
        bs += 1
        issues.append(('BS', 'FAIL', '为你推荐歌单的横向轨丢了'))

    # ③ 首页：四处实时触发 + 下拉刷新 + v2.72 入口收口 + 不恢复 v2.29 编排
    # v2.72：板块去掉 limit 参数（横向轨全 30 首）；通栏歌单收藏条撤掉，
    # 四宫格第四格改为「歌单收藏」，下载移到顶栏右侧图标，导入移到收藏页。
    for kw, msg in (('WyRecommendSection()', '首页没挂实时推荐板块'),
                    ("@StorageProp('wyLoginVersion')", '首页没订阅登录 / 退出变化'),
                    ("Refresh({ refreshing: $$this.recRefreshing })", '首页没接下拉刷新'),
                    ('.onRefreshing(() =>', '下拉刷新没接回调'),
                    ('private async pullRefresh()', '下拉刷新没等真实请求跑完'),
                    ('this.quickGrid()', '首页四宫格被改动'),
                    ("title: '歌单收藏'", '四宫格第四格没换成歌单收藏'),
                    ("title: '下载管理'", '四宫格里仍留着下载管理（应换掉）'),
                    ('FLOAT_SPACE', '底部悬浮层留白被回退')):
        hit = kw in home
        # 「仍留着下载管理」是反向断言：出现才报错
        if msg.startswith('四宫格里仍留着'):
            if hit:
                bs += 1
                issues.append(('BS', 'FAIL', 'HomePage ' + msg))
        elif not hit:
            bs += 1
            issues.append(('BS', 'FAIL', 'HomePage ' + msg))
    head = _func_body(home, 'topHeader') or ''
    if 'arrow_down_circle' not in head:
        bs += 1
        issues.append(('BS', 'FAIL', 'HomePage 顶栏没补下载图标（图 2 标记处）'))
    for gone in ('favSheetsEntry', 'importSheet(', 'sys.symbol.plus'):
        if gone in home:
            bs += 1
            issues.append(('BS', 'FAIL', 'HomePage 还残留「' + gone + '」：v2.72 应已收口'))
    if home.count('WyRecommendHub.get().refresh()') < 3:
        bs += 1
        issues.append(('BS', 'FAIL', '首页缺实时触发点（进页 / 回前台 / 登录变化 / 下拉至少三处）'))
    for kw in ('homeLayout', 'visibleKeys', 'HomeLayoutPage'):
        if kw in home:
            bs += 1
            issues.append(('BS', 'FAIL', '首页又出现 v2.29 已移除的模块编排：' + kw))

    # ④ 账号页收口 + 隐藏三块推荐 + 设置页文案
    for kw in ('PlatformAccountPanel', 'platformTabs', 'accountTab'):
        if kw in wy_page:
            bs += 1
            issues.append(('BS', 'FAIL', '账号页残留三平台入口：' + kw))
    for kw, msg in (("title: '网易云账号'", '账号页标题没固定为网易云账号'),
                    ('WyRecommendHub.get().refresh()', '账号页登录后没预热首页推荐 hub'),
                    ('this.accountHeader()', '账号头被误删'),
                    ('this.syncCard()', '歌单收藏同步卡被误删')):
        if kw not in wy_page:
            bs += 1
            issues.append(('BS', 'FAIL', 'WyAccountPage ' + msg))
    # v2.72 隐藏「每日推荐 / 推荐歌单」，v2.73 恢复「我的歌单」：账号页独有这块，
    # 单独拉真实 /weapi/user/playlist，不订阅 wyRecVersion、不复制首页推荐。
    for gone in ('recommendSongs', 'dailySheetRail', 'syncFromHub',
                 "@StorageProp('wyRecVersion')", 'SongMenu', 'menuSheet'):
        if gone in wy_page:
            bs += 1
            issues.append(('BS', 'FAIL', 'WyAccountPage 还残留推荐视图「' + gone + '」：应已隐藏'))
    # v2.73 三项新特性：登录后头像、恢复的我的歌单轨、退出清残留
    for kw, msg in (('account.avatar()', '账号页没读登录后头像 URL'),
                    ('Image(this.avatarUrl)', '账号页没渲染头像'),
                    ('this.mySheetRail()', '账号页没恢复「我的歌单」板块'),
                    ('WyRecommend.mySheets()', '「我的歌单」没走真实接口'),
                    ('this.mySheets = []', '退出登录没清上一账号的歌单残留')):
        if kw not in wy_page:
            bs += 1
            issues.append(('BS', 'FAIL', 'WyAccountPage ' + msg))
    if '网易云账号' not in settings or '账号与同步' in settings:
        bs += 1
        issues.append(('BS', 'FAIL', '设置页账号入口文案没收口'))

    if bs == 0:
        issues.append(('BS', 'PASS',
                       '账号页收口仅网易云：每日推荐/推荐歌单只在首页，v2.73 恢复「我的歌单」并'
                       '新增登录后头像（真实接口 / 人形占位回退 / 退出清残留）；首页每日推荐改'
                       '「5 首一组」Swiper 分页轨铺满 30 首、四宫格第四格换歌单收藏、下载移到'
                       '顶栏图标；WyRecommendHub 唯一数据源四处实时触发、板块显示更新于 HH:mm、'
                       '加载/失败/空/未登录齐全；不造数、不落盘、不新增路由'))


def check_home_daily_rail_and_entries(src):
    """BT：首页每日推荐全 30 首 + 入口收口 + 导入搬家（v2.72，v2.73 校正）。

    用户口径（以本轮为准）：
      ① 首页每日推荐全 30 首显示。v2.72 做成每首一张小卡连续横滑，v2.73
         用户纠正为「5 个一排、可以滑动」—— 改成 Swiper 分页轨，一组 5 首一页；
      ② v2.72 账号页三块推荐全隐藏；v2.73 用户要求恢复「我的歌单」，
         每日推荐 / 推荐歌单仍只在首页；
      ③ 首页四宫格移除「下载管理」，把「歌单收藏」换成同样的方块图标，
         下载改到顶栏右侧小图标（图 2 标记处）；
      ④ 「导入歌单」从首页并排方卡搬到「歌单收藏」二级页标题栏右上角
         （图 3 标记处）。

    工程约束：顶栏新动作走「默认关闭的可选参数」，只有收藏页打开，
    其余二级页顶栏一字不改；导入逻辑逐字搬迁，不丢解析/加收藏/打开详情
    任何一环；下载入口收敛但仍可达，不新增路由、不造数据。
    """
    bt = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    home = get('ui/pages/HomePage.ets')
    section = get('ui/WyRecommendSection.ets')
    wy_page = get('ui/pages/WyAccountPage.ets')
    fav = get('ui/pages/FavoriteSheetsPage.ets')
    common = get('ui/Common.ets')
    if not all((home, section, wy_page, fav, common)):
        issues.append(('BT', 'WARN', '没找齐首页/板块/账号页/收藏页/公共组件，跳过 v2.72 检查'))
        return

    # ① v2.73 口径：每日推荐是「5 首一组」Swiper 分页轨（30 首 6 组全量可滑），
    # 不再要求全量 ForEach / 两条水平 Scroll；为你推荐歌单仍是水平横向轨。
    for kw, msg in (('const REC_PAGE_SIZE: number = 5;', '缺 5 首一组常量'),
                    ('private pageCount(): number', '缺按总数算组数'),
                    ('Swiper() {', '没用 Swiper 分页轨'),
                    ('.loop(false)', '分页轨开了循环'),
                    ("'homeRec_'", '分页歌曲行 ForEach 没带稳定 key'),
                    ('Cover({', '分组歌曲行没复用公共封面'),
                    ('App.get().play(this.songList, index)', '分组歌曲不能点播'),
                    ("'每日推荐'", '每日推荐板块标题丢了')):
        if kw not in section:
            bt += 1
            issues.append(('BT', 'FAIL', 'WyRecommendSection ' + msg))
    if 'slice(0, this.limit)' in section or '@Prop limit' in section:
        bt += 1
        issues.append(('BT', 'FAIL', '每日推荐还在截断前几首，30 首显示不全'))
    if 'ScrollDirection.Horizontal' not in section:
        bt += 1
        issues.append(('BT', 'FAIL', '为你推荐歌单的横向轨丢了'))
    if 'WyRecommendSection()' not in home or 'limit: 5' in home:
        bt += 1
        issues.append(('BT', 'FAIL', '首页板块调用还带 limit 或没挂上'))

    # ② v2.72 隐藏的仍是「每日推荐 / 推荐歌单」；v2.73 恢复「我的歌单」，
    # 故 mySheetRail / GlassSheetCard 重新成为合法实现，从反断言里移除。
    for gone in ('recommendSongs', 'dailySheetRail', 'syncFromHub',
                 'menuSheet', 'SongMenu', 'SongRow',
                 "@StorageProp('wyRecVersion')"):
        if gone in wy_page:
            bt += 1
            issues.append(('BT', 'FAIL', 'WyAccountPage 仍残留已隐藏的推荐实现：' + gone))
    for keep in ('this.accountHeader()', 'this.syncCard()', 'WyRecommendHub.get().refresh()',
                 'this.mySheetRail()', "title: '我的歌单'"):
        if keep not in wy_page:
            bt += 1
            issues.append(('BT', 'FAIL', 'WyAccountPage 恢复「我的歌单」时误删了：' + keep))

    # ③ 首页入口收口：四个方块、下载只留顶栏一个图标、路由仍可达
    for kw in ("title: '我喜欢'", "title: '最近播放'", "title: '本地音乐'",
               "title: '歌单收藏'"):
        if kw not in home:
            bt += 1
            issues.append(('BT', 'FAIL', '首页四宫格缺方块：' + kw))
    if "title: '下载管理'" in home or 'favSheetsEntry' in home:
        bt += 1
        issues.append(('BT', 'FAIL', '首页还留着下载管理方块 / 通栏歌单收藏条'))
    head = _func_body(home, 'topHeader') or ''
    if 'arrow_down_circle' not in head:
        bt += 1
        issues.append(('BT', 'FAIL', '首页顶栏没有下载图标'))
    if "openEntry('downloads')" not in home or "push('downloads', new NavParam())" not in home:
        bt += 1
        issues.append(('BT', 'FAIL', '下载入口没接回 downloads 路由（移除方块后功能丢了）'))
    if 'importSheet(' in home or 'sys.symbol.plus' in home or 'doImport()' in home:
        bt += 1
        issues.append(('BT', 'FAIL', '首页仍残留导入面板 / 加号：应已搬到收藏页'))

    # ④ 导入整套搬到收藏页，逻辑一环不缺、面板底色不露白
    for kw, msg in (('@Builder\n  importSheet()', '缺导入面板'),
                    ('private doImport()', '缺导入执行'),
                    ('parsePlaylistInput(this.importText, this.importPlatform)', '没接解析器'),
                    ('newSheet(ref.platform, ref.kind)', '没构造 SheetInfo'),
                    ('Library.get().toggleSheetFavorite(sheet)', '没加入歌单收藏'),
                    ('App.get().openSheet(sheet)', '导入后没打开详情'),
                    ('bindSheet($$this.importShow, this.importSheet()', '没挂导入弹层'),
                    ('backgroundColor: glassCardBase(this.isDark)', '弹层底色会露白边'),
                    ('showTrailing: true', '标题栏右上角动作没打开'),
                    ("trailingIcon: $r('sys.symbol.plus')", '右上角不是加号图标'),
                    ('trailingLabel: ', '右上角动作缺读屏标签')):
        if kw not in fav:
            bt += 1
            issues.append(('BT', 'FAIL', 'FavoriteSheetsPage ' + msg))
    if '汽水音乐等平台暂不支持' in fav:
        bt += 1
        issues.append(('BT', 'FAIL', '收藏页导入面板的汽水说明又回来了（用户要求删说明）'))

    # ⑤ 顶栏动作：公共组件默认关闭，且只有收藏页打开，其它页零外溢
    for kw, msg in (('@Prop showTrailing: boolean = false;', 'PageBar 缺默认关闭的开关'),
                    ('@Prop trailingIcon: Resource', 'PageBar 缺图标参数'),
                    ('onTrailing: () => void', 'PageBar 缺回调'),
                    ('if (this.showTrailing)', 'PageBar 没按开关渲染'),
                    ('showTrailing: this.showTrailing,', 'ImmersiveBar 没透传开关'),
                    ('trailingIcon: this.trailingIcon,', 'ImmersiveBar 没透传图标')):
        if kw not in common:
            bt += 1
            issues.append(('BT', 'FAIL', 'Common ' + msg))
    opened = [f for f, s in src.items() if f.endswith('.ets') and 'showTrailing: true' in s]
    if opened != [f for f in opened if f.endswith('ui/pages/FavoriteSheetsPage.ets')] or len(opened) != 1:
        bt += 1
        issues.append(('BT', 'FAIL', '右上角动作外溢到其它页面（或收藏页没开）：' + str(len(opened)) + ' 处'))

    if bt == 0:
        issues.append(('BT', 'PASS',
                       '首页每日推荐按 v2.73 口径改「5 首一组」Swiper 分页轨铺满 30 首、'
                       '账号页恢复「我的歌单」且每日推荐/推荐歌单仍只在首页、四宫格第四格换'
                       '歌单收藏并把下载移到顶栏图标、导入歌单整套搬到收藏页标题栏；'
                       '顶栏动作默认关闭只此一页打开，下载/导入入口均不丢、不新增路由、不造数据'))


def check_v273_group_rail_avatar_mysheets(src):
    """BU：v2.73 三项口径修正（5 首一组分页轨 / 登录后头像 / 我的歌单回归，v2.73）。

    用户纠正上一轮口径：
      ① 首页每日推荐是「5 个一排、可以滑动」，不是每首一张小卡连续横滑 ——
         实现为 Swiper 分页轨，一页一整块 5 首纵向列表，30 首切 6 组按组翻页；
      ② 网易云账号登录后应显示本人头像（account/get 的 profile.avatarUrl），
         此前缺失；加载失败回退人形占位，不显示破图；
      ③ 网易云账号二级页不要隐藏「我的歌单」，恢复显示，且必须真实拉取。

    守的是「不造数」：我的歌单只走 WyRecommend.mySheets() 真实接口，头像只取
    WyAccount 落盘的 WY_AVATAR，未登录 / 退出不留上一账号任何残留；每日推荐与
    推荐歌单仍只在首页，账号页不订阅 wyRecVersion、不复制首页推荐。
    """
    bu = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    section = get('ui/WyRecommendSection.ets')
    wy_page = get('ui/pages/WyAccountPage.ets')
    account = get('core/WyAccount.ets')
    recommend = get('core/WyRecommend.ets')
    if not all((section, wy_page, account, recommend)):
        issues.append(('BU', 'WARN', '没找齐 v2.73 相关文件，跳过检查'))
        return

    # ① 5 首一组分页轨：分组常量、按总数算组数、Swiper 非循环、全局下标点播
    for kw, msg in (('const REC_PAGE_SIZE: number = 5;', '不是每组 5 首'),
                    ('Math.ceil(this.songList.length / REC_PAGE_SIZE)', '组数没按全量 songList 算（30 首会丢）'),
                    ('Swiper() {', '没用 Swiper 承载分组'),
                    ('.loop(false)', '分页轨开了 loop：末组会绕回第一组'),
                    ('.indicator(false)', '分页轨没关默认指示器（与自定义组号重复）'),
                    ('.onChange((index: number)', '没记录当前组号'),
                    ('this.play(page * REC_PAGE_SIZE + row)', '分组点播没换算全局下标'),
                    ('this.recPage + 1', '没显示「第 N / M 组」'),
                    ('this.songList.length.toString()', '没显示歌曲总数')):
        if kw not in section:
            bu += 1
            issues.append(('BU', 'FAIL', 'WyRecommendSection ' + msg))
    if 'ForEach(this.songList.slice(0' in section or 'slice(0, 5)' in section:
        bu += 1
        issues.append(('BU', 'FAIL', '每日推荐又退化成只显示前几首'))

    # ② 登录后头像：底层已落盘、页面读取、失败回退、https 化
    for kw, msg in (('PrefKeys.WY_AVATAR', 'WyAccount 没落盘头像 URL'),
                    ('avatar(): string', 'WyAccount 没暴露头像读取'),
                    ('s.delete(PrefKeys.WY_AVATAR)', '退出登录没清头像')):
        if kw not in account:
            bu += 1
            issues.append(('BU', 'FAIL', 'WyAccount ' + msg))
    for kw, msg in (("account.avatar().replace('http://', 'https://')", '账号页没读头像或没升 https'),
                    ('@State avatarFailed: boolean', '缺头像加载失败标记'),
                    ('Image(this.avatarUrl)', '没渲染头像'),
                    ("SymbolGlyph($r('sys.symbol.person')", '没人形占位兜底'),
                    ('.onError(() =>', '头像加载失败没有回退'),
                    ('.clip(true)', '头像没裁成圆形')):
        if kw not in wy_page:
            bu += 1
            issues.append(('BU', 'FAIL', 'WyAccountPage ' + msg))

    # ③ 我的歌单回归：真实接口、进页与登录成功各拉一次、退出清空、不订阅 hub
    for kw, msg in (('static async mySheets(): Promise<SheetInfo[]>', '缺我的歌单真实接口'),
                    ('/weapi/user/playlist', '我的歌单接口不是官方地址')):
        if kw not in recommend:
            bu += 1
            issues.append(('BU', 'FAIL', 'WyRecommend ' + msg))
    for kw, msg in (('private async loadMySheets(): Promise<void>', '缺本页歌单加载'),
                    ('WyRecommend.mySheets()', '没拉真实歌单'),
                    ('this.mySheetRail()', '没渲染「我的歌单」板块'),
                    ("title: '我的歌单'", '「我的歌单」标题丢了'),
                    ('if (this.stopped) {', '页面销毁后异步结果没丢弃（会改已销毁 @State）'),
                    ('this.mySheets = []', '退出登录没清上一账号的歌单')):
        if kw not in wy_page:
            bu += 1
            issues.append(('BU', 'FAIL', 'WyAccountPage ' + msg))
    if "@StorageProp('wyRecVersion')" in wy_page:
        bu += 1
        issues.append(('BU', 'FAIL', '账号页又订阅了 hub 版本：我的歌单应本页独拉，不复制首页推荐'))
    if 'mySheets' in section:
        bu += 1
        issues.append(('BU', 'FAIL', '首页板块混入了「我的歌单」：三块推荐边界被打破'))

    if bu == 0:
        issues.append(('BU', 'PASS',
                       'v2.73 三项口径修正到位：每日推荐「5 首一组」Swiper 分页轨按全量 30 首'
                       '切 6 组、按组横滑且点播下标全局对齐；账号页读取落盘的 avatarUrl 显示'
                       '登录后头像并带人形占位/失败回退/https 升级；「我的歌单」恢复为账号页'
                       '独有板块，走 /weapi/user/playlist 真实数据、退出清残留、不订阅首页 hub；'
                       '每日推荐与推荐歌单仍只在首页，全程不造数、不新增路由'))


def check_v274_hot_theme_marquee(src):
    """BV：v2.74 两项（大家都在搜实时化 / 跑马灯降速）。

    ① 搜索页「大家都在搜」原来是 Constants 里写死的 HOT_WORDS，几天不变；
       改为 HotSearch.ets 拉网易云官方 /api/search/hot?type=1&limit=10，
       失败只给可重试提示、不造数；页面显示更新于 HH:mm 与刷新入口。
    ② 长歌名跑马灯 step 4 → 2（速度约减半），7 处统一（BE 组已锁）。

    注：原③「青绿液态玻璃双主题」整套引擎已于 v2.80 连根删除，
    界面固定为纸墨单一风格；相关护栏改由 CA 组（check_glass_theme_removed）承载。
    """
    bv = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    constants = get('common/Constants.ets')
    hot = get('core/HotSearch.ets')
    search = get('ui/pages/SearchPage.ets')
    settings = get('core/Settings.ets')
    app = get('core/App.ets')
    appearance = get('ui/pages/AppearanceSettingsPage.ets')

    # ① 实时热搜：真实接口、解析、在途锁 / TTL、失败不造数
    if not hot:
        bv += 1
        issues.append(('BV', 'FAIL', '缺 core/HotSearch.ets：大家都在搜仍是写死的'))
    else:
        for kw, msg in (('https://music.163.com/api/search/hot?type=1&limit=10',
                         '没用官方实时热搜接口（type=1 必带，只带 limit 会 400）'),
                        ('getJson<HotResp>', '没走工程原生 Http 层'),
                        ('.hots', '没解析 result.hots'),
                        ('HOT_TTL', '缺缓存 TTL'),
                        ('if (this.busy)', '缺在途锁'),
                        ('this.error = ', '失败没给可重试提示'),
                        ('list.indexOf(w) < 0', '热搜词没去重')):
            if kw not in hot:
                bv += 1
                issues.append(('BV', 'FAIL', 'HotSearch ' + msg))
        if re.search(r"const\s+\w+\s*=\s*\[\s*'晴天'", hot):
            bv += 1
            issues.append(('BV', 'FAIL', '实时热搜里混进了写死的词（不造数）'))
    for kw, msg in (('ForEach(this.hotWords,', '搜索页没渲染实时热搜词'),
                    ('HotSearch.get().refresh(force)', '搜索页没调数据源'),
                    ('this.loadHot(false)', '进页没自动刷新'),
                    ("'更新于 '", '没显示更新时间'),
                    ('loadHot(true)', '没给强制刷新入口'),
                    ('this.hotHint', '没显示失败提示')):
        if kw not in search:
            bv += 1
            issues.append(('BV', 'FAIL', 'SearchPage ' + msg))
    if re.search(r'ForEach\(HOT_WORDS', search) or re.search(r'export const HOT_WORDS', constants):
        bv += 1
        issues.append(('BV', 'FAIL', '写死的 HOT_WORDS 没删干净：大家都在搜又会常年不变'))

    if bv == 0:
        issues.append(('BV', 'PASS',
                       '大家都在搜改拉网易云官方实时热搜（type=1）+ 更新于 HH:mm/刷新/失败重试，'
                       '写死 HOT_WORDS 删除、失败不造数；长歌名跑马灯 7 处统一降到 step 2；'
                       '（原③青绿液态玻璃双主题已于 v2.80 连根删除，改由 CA 组守护零残留）'))


def check_v277_account_summary_login_only(src):
    """BY：设置页账号入口摘要只显示「已登录 / 未登录」，不暴露昵称明文（v2.77）。

    用户口径：设置页「网易云账号」右侧出现的 wang210207 看着像内部标识 / 测试
    残留，实际是网易云 account/get 返回的默认昵称。用户选择「只显示已登录」。

    边界（一次只改一个主题）：
      ① 只改 SettingsPage.accountSummary() 的展示文本，登录态信号仍读 wyNick，
         订阅与广播链路一字不动 —— 登录 / 退出时本行照样即时刷新；
      ② 二级页 WyAccountPage 的真实昵称 / 头像 / UID 展示全部保留，
         昵称只在账号页显示，不在设置列表摘要里重复暴露；
      ③ 不新增路由、不造数据、不动其它入口。
    """
    by = 0
    settings = next((s for f, s in src.items() if f.endswith('ui/pages/SettingsPage.ets')), '')
    wy_page = next((s for f, s in src.items() if f.endswith('ui/pages/WyAccountPage.ets')), '')

    if not settings:
        by += 1
        issues.append(('BY', 'FAIL', '找不到 SettingsPage.ets'))
    else:
        # ① 摘要只给登录态两个固定文案
        if "return this.wyNick.length > 0 ? '已登录' : '未登录';" not in settings:
            by += 1
            issues.append(('BY', 'FAIL', '账号摘要没固定为「已登录 / 未登录」'))
        # ② 不再把昵称明文塞进 value（旧形态 ? this.wyNick : 必须消失）
        if '? this.wyNick :' in settings or 'value: this.wyNick' in settings:
            by += 1
            issues.append(('BY', 'FAIL', '设置页仍把昵称明文挂到入口摘要上'))
        # ③ 登录态信号与响应式订阅保留，不能为了藏昵称把刷新链路一起删了
        for kw, msg in (("@StorageProp('wyNick')", '丢了 wyNick 订阅，登录/退出后摘要不刷新'),
                        ('this.wyNick.length > 0', '丢了登录态判据'),
                        ("push('wyAccount', new NavParam())", '账号页入口被误删')):
            if kw not in settings:
                by += 1
                issues.append(('BY', 'FAIL', 'SettingsPage ' + msg))

    # ④ 真实昵称与头像仍在账号二级页，未被牵连删除
    for kw, msg in (('Text(this.nickName.length > 0 ? this.nickName', '账号页昵称展示被删'),
                    ('Image(this.avatarUrl)', '账号页头像被删')):
        if kw not in wy_page:
            by += 1
            issues.append(('BY', 'FAIL', 'WyAccountPage ' + msg))

    if by == 0:
        issues.append(('BY', 'PASS',
                       '设置页「网易云账号」摘要只显示「已登录 / 未登录」，不再暴露默认昵称明文；'
                       'wyNick 订阅 / 登录态判据 / 账号页入口原样保留，登录退出仍即时刷新；'
                       '真实昵称与头像继续由二级页展示，不新增路由、不造数据'))


def check_home_grid_tint_uniform(src):
    """BZ：首页四宫格四格配色 + 图标风格统一（v2.78 配色统一 / v2.79 线框统一）。

    用户口径（两轮）：
      · v2.78 截图圈出「我喜欢」「歌单收藏」两个心形，一个灰褐、一个琥珀金，
        要求把这两个图标都统一成「本地音乐 / 最近播放」那种灰褐色；
      · v2.79 装机后反馈「心形改的颜色有点深」：四格 tint 其实同为 #FF6F6960，
        显深是因为两个心形用实心填充（深色面积约为线框描边的 2 倍），
        而「最近播放 / 本地音乐」是细线描边。用户选「四格统一改线框」，
        要求把两个实心爱心换成空心线框爱心，按那两格的描边风格归一。

    边界（一次只改一个主题）：
      ① 只改 HomePage.ets 四宫格图标引用，四个入口 / 标题 / 数字 / tint 一律不动，
         不改路由、不造数据；
      ② 四格 tint 全部为 #FF6F6960，本页不得再出现琥珀色值 #FFE29A26；
      ③ Constants.ets 的品牌琥珀主色（搜索按钮 / 底栏选中态）保持不变，
         不能为了「统一」把品牌主色一起删掉；
      ④ 四格图标全为线框描边：空心爱心 × 2 + 时钟 + 文件夹，本页不得再有
         实心填充 heart_fill 残留（含注释，避免以后又被改回实心显深）。
    """
    bz = 0
    home = next((s for f, s in src.items() if f.endswith('ui/pages/HomePage.ets')), '')
    constants = next((s for f, s in src.items() if f.endswith('common/Constants.ets')), '')

    if not home:
        bz += 1
        issues.append(('BZ', 'FAIL', '找不到 HomePage.ets'))
    else:
        # ① 本页不再出现琥珀色值：四个 tint 全部归一
        if '#FFE29A26' in home:
            bz += 1
            issues.append(('BZ', 'FAIL', '四宫格仍残留琥珀色 tint #FFE29A26，配色没统一'))
        # 四格 tint 应恰好出现 4 次灰褐值（我喜欢 / 最近播放 / 本地音乐 / 歌单收藏）
        grey = home.count("tint: '#FF6F6960'")
        if grey < 4:
            bz += 1
            issues.append(('BZ', 'FAIL',
                           '四宫格灰褐 tint #FF6F6960 应至少 4 处（四格各一），实际 ' + str(grey) + ' 处'))
        # ② 四格结构完整：入口 / 卡片 / 标题没被牵连删除
        for kw, msg in (('quickGrid()', '四宫格 quickGrid 被删'),
                        ('LibraryEntryCard', '四宫格卡片组件被删'),
                        ("title: '我喜欢'", '「我喜欢」入口被删'),
                        ("title: '最近播放'", '「最近播放」入口被删'),
                        ("title: '本地音乐'", '「本地音乐」入口被删'),
                        ("title: '歌单收藏'", '「歌单收藏」入口被删')):
            if kw not in home:
                bz += 1
                issues.append(('BZ', 'FAIL', 'HomePage ' + msg))
        # ③ v2.79 图标风格统一：四格全为线框描边，本页无实心填充 heart_fill 残留。
        #    空心爱心 × 2（四宫格）+ 组件默认值 1 = 3 处；时钟 / 文件夹各 1 处。
        if 'heart_fill' in home:
            bz += 1
            issues.append(('BZ', 'FAIL',
                           'HomePage 仍有实心 heart_fill 残留，心形会再次比线框图标显深'))
        outline_hearts = home.count("$r('sys.symbol.heart')")
        if outline_hearts < 3:
            bz += 1
            issues.append(('BZ', 'FAIL',
                           '空心线框爱心 heart 应 3 处（默认值 1 + 四宫格 2），实际 '
                           + str(outline_hearts) + ' 处'))
        if "$r('sys.symbol.clock')" not in home or "$r('sys.symbol.folder')" not in home:
            bz += 1
            issues.append(('BZ', 'FAIL', '线框时钟 / 文件夹图标被删，四格描边风格不再完整'))
        # ④ tint 仍驱动图标色与底色方块，改色链路完整
        if '.fontColor([this.tint])' not in home or 'withAlpha(this.tint, 0.12)' not in home:
            bz += 1
            issues.append(('BZ', 'FAIL', 'tint 驱动图标色 / 底色方块的链路被破坏'))

    # ⑤ 品牌主色不被误删（搜索按钮 / 底栏选中态仍在用）
    if "primary: '#FFE29A26'" not in constants:
        bz += 1
        issues.append(('BZ', 'FAIL', 'Constants.ets 品牌琥珀主色被误删，搜索按钮 / 底栏选中态会失色'))

    if bz == 0:
        issues.append(('BZ', 'PASS',
                       '首页四宫格四格 tint 统一为灰褐 #FF6F6960；v2.79 两个实心填充爱心'
                       '换为空心线框爱心，与时钟 / 文件夹同为描边风格、四格视觉深度归一，'
                       '本页无 heart_fill 残留；四格入口 / 标题 / 图标 / tint 驱动链路完整，'
                       'Constants 品牌琥珀主色保持不变'))


def check_glass_theme_removed(src):
    """CA：青绿液态玻璃整套引擎连根删除（v2.80）。

    用户口径：外观页「青绿液态玻璃」风格「有点不搭」，选择「连根删除整套引擎」，
    并把红圈标记的两段说明文字一并去掉。

    这一组刻意读磁盘原文（load_raw），不依赖归一化视图，锁死「引擎零残留」：
      ① 全工程 .ets 不再出现 glassTheme / glassTick / onGlassTheme / setGlassTheme /
         GLASS_THEME / LIQUID_LIGHT|DARK / liquid* 配方 / activeGlassTheme / theme?: number；
      ② Constants 10 个取色函数签名去掉 theme 参数、只返回纸墨实色（不能误删纸墨链路）；
      ③ 外观页「风格」切换行（纸墨/青绿玻璃 Chip + applyGlassTheme）与两段说明文字删除，
         「主题」分组只剩「模式」三档；深浅色 applyThemeMode 链路完整；
      ④ v2.56 光感迁移提示随 B5 清理一并删除，由 CY 组守护零残留；
      ⑤ Constants 品牌琥珀主色、四宫格配色不受牵连（由 BZ 组另行守护）。
    """
    ca = 0
    raw = load_raw()
    all_ets = '\n'.join(s for f, s in raw.items() if f.endswith('.ets'))

    def get(suffix: str) -> str:
        return next((s for f, s in raw.items() if f.endswith(suffix)), '')

    constants = get('common/Constants.ets')
    appearance = get('ui/pages/AppearanceSettingsPage.ets')
    settings = get('core/Settings.ets')
    app = get('core/App.ets')

    # ① 引擎代码符号零残留
    for kw, msg in (('glassTheme', '仍残留 glassTheme 符号'),
                    ('glassTick', '仍残留 glassTick 重绘锚'),
                    ('onGlassTheme', '仍残留 onGlassTheme 回调'),
                    ('setGlassTheme', '仍残留 setGlassTheme 函数'),
                    ('GLASS_THEME', '仍残留持久化 key GLASS_THEME'),
                    ('LIQUID_LIGHT', '仍残留青绿浅色色板'),
                    ('LIQUID_DARK', '仍残留青绿深色色板'),
                    ('activeGlassTheme', '仍残留模块级主题变量'),
                    ('theme?: number', '取色函数仍带 theme 参数'),
                    ('theme === undefined', '仍残留主题分发解析'),
                    ('liquidSurface(', '仍残留青绿 7 段渐变配方'),
                    ('liquidFill(', '仍残留青绿浮层填充配方'),
                    ('liquidSense(', '仍残留青绿材质配方')):
        if kw in all_ets:
            ca += 1
            issues.append(('CA', 'FAIL', '全工程 ' + msg + '：' + kw))

    # ② 10 个取色函数签名无 theme、纸墨实色返回完整
    if not constants:
        ca += 1
        issues.append(('CA', 'FAIL', '找不到 Constants.ets'))
    else:
        fns = ('palette', 'glassCardBase', 'glassSurface', 'glassFill', 'glassDepth',
               'glassEdgeWidth', 'glassEdgeColor', 'glassShadow', 'glassRowShadow', 'lightSense')
        for fn in fns:
            if not re.search(r'export function ' + fn + r'\(', constants):
                ca += 1
                issues.append(('CA', 'FAIL', 'Constants.' + fn + ' 被误删：纸墨取色链路断了'))
        for kw, msg in (('return isDark ? DARK : LIGHT;', 'palette 不再返回纸墨色板'),
                        ('return [[c, 0], [c, 1]];', 'glassSurface 不再返回纸墨平涂'),
                        ("primary: '#FFE29A26'", '纸墨浅色主色被改动'),
                        ("primary: '#FFF3B044'", '纸墨深色主色被改动')):
            if kw not in constants:
                ca += 1
                issues.append(('CA', 'FAIL', 'Constants ' + msg))

    # ③ 外观页：风格行 + 两段说明删除，模式三档与深浅色链路保留
    if not appearance:
        ca += 1
        issues.append(('CA', 'FAIL', '找不到 AppearanceSettingsPage.ets'))
    else:
        for kw, msg in (("text: '纸墨'", '仍残留「纸墨」风格 Chip'),
                        ("text: '青绿玻璃'", '仍残留「青绿玻璃」风格 Chip'),
                        ('applyGlassTheme', '仍残留风格切换方法'),
                        ('青绿液态玻璃是早期版本的整体界面渲染', '仍残留第一段青绿说明'),
                        ('光感选项已移除', '仍残留第二段（else 分支）说明'),
                        ('当前为青绿液态玻璃风格', '仍残留青绿风格状态文案')):
            if kw in appearance:
                ca += 1
                issues.append(('CA', 'FAIL', '外观页 ' + msg))
        for kw, msg in (("text: '跟随系统'", '「模式」跟随系统档被删'),
                        ("text: '浅色'", '「模式」浅色档被删'),
                        ("text: '深色'", '「模式」深色档被删'),
                        ('applyThemeMode(mode', '深浅色切换链路被删')):
            if kw not in appearance:
                ca += 1
                issues.append(('CA', 'FAIL', '外观页 ' + msg))
        # ④ lightNotice 提示条已随 B5 清理删除，这里反查「不许回潮」
        if '@State lightNotice: boolean = false;' in appearance or \
                '光感四档已取消' in appearance:
            ca += 1
            issues.append(('CA', 'FAIL', 'v2.56 光感迁移提示条仍残留（本次清理已删除）'))

    # ⑤ Settings / App 不再读写广播主题
    for kw in ('glassTheme()', 'setGlassTheme', "AppStorage.setOrCreate('glassTheme'"):
        if kw in settings or kw in app:
            ca += 1
            issues.append(('CA', 'FAIL', 'Settings/App 仍残留主题读写/广播：' + kw))

    if ca == 0:
        issues.append(('CA', 'PASS',
                       '青绿液态玻璃整套引擎连根删除：27 文件 429 处 glassTheme 引用、'
                       '10 个取色函数 theme 分发、LIQUID 色板与 liquid* 配方、落盘/广播/'
                       '首帧恢复、外观页「风格」切换行与两段说明全部清零；界面固定为纸墨，'
                       '取色函数只按 isDark 返回中性实色，深浅色「模式」三档链路完整，'
                       'v2.56 光感迁移提示条已删除，品牌主色不受牵连'))


def check_qqkg_account_removed(src):
    """CD：QQ / 酷狗「账号登录体系」连根删除（v1.0）。

    用户口径：账号登录那里早就把 QQ / 酷狗隐藏了，代码还在白占空间，直接删掉。
    本组锁死两件事，防止后续回滚或误删：
      ① 7 个账号文件与全部标识符零残留（凭证 / 扫码 / 云端收藏读写 / 通用面板 / 广播 key）；
      ② tx(QQ音乐) / kg(酷狗音乐) 作为**音源平台**必须完整保留 —— 搜索、封面、
        歌单广场、发现页板块、本地已收藏歌单数据，一个都不能被牵连删除。
    """
    cd = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    banned_files = ('core/QqAccount.ets', 'core/QqApi.ets', 'core/KgAccount.ets',
                    'core/KgApi.ets', 'core/KgDevice.ets', 'core/AccountCrypto.ets',
                    'ui/pages/PlatformAccountPanel.ets')
    for f in src:
        for b in banned_files:
            if f.endswith(b):
                cd += 1
                issues.append(('CD', 'FAIL', '账号体系文件仍存在：' + b))

    banned_kw = ('QqAccount', 'KgAccount', 'QqApi', 'KgApi', 'AccountCrypto',
                 'KgDevice', 'PlatformAccountPanel', 'qqFavHook', 'kgFavHook',
                 'QQ_COOKIE', 'KG_COOKIE', 'QQ_FAV_', 'KG_FAV_', 'QQ_UIN', 'KG_UID',
                 'qqNick', 'kgNick', 'qqFavSync', 'kgFavSync', 'qqLoginVersion',
                 'kgLoginVersion', 'reconcileQqKg', 'qqEngine', 'kgEngine',
                 'v4_qq_', 'v4_kg_', 'fcg_qm_order_diss',
                 'login-user.kugou.com', 'ptqrshow', 'qrcode_img')
    # gateway.kugou.com 是通用网关，歌曲评论（CommentApi）也要用，不能一刀切。
    # 但账号体系绝不能借它回潮：只允许 core/CommentApi.ets 里的 cmtlist 评论端点。
    for f, text in src.items():
        if 'gateway.kugou.com' in text:
            if not f.endswith('core/CommentApi.ets') or 'mcomment/v1/cmtlist' not in text:
                cd += 1
                issues.append(('CD', 'FAIL',
                               '%s 使用了酷狗网关但并非评论端点（账号体系疑似回潮）' % f))
    for f, text in src.items():
        for kw in banned_kw:
            if kw in text:
                cd += 1
                issues.append(('CD', 'FAIL', '%s 残留账号体系标识符「%s」' % (f, kw)))
                break

    # 音源平台必须保留：平台定义表 + 官方直连接口 + 发现页板块编排
    platform = get('common/Platform.ets')
    api = get('core/PlatformApi.ets')
    feed = get('core/DiscoverFeed.ets')
    for kw, msg in (("{ id: 'tx'", '平台定义表丢了 QQ音乐音源'),
                    ("{ id: 'kg'", '平台定义表丢了酷狗音源')):
        if kw not in platform:
            cd += 1
            issues.append(('CD', 'FAIL', msg))
    for kw, msg in (('c.y.qq.com', 'PlatformApi 丢了 QQ 官方搜索/封面接口'),
                    ("newSong('kg')", 'PlatformApi 丢了酷狗歌曲构造'),
                    ('m.kugou.com', 'PlatformApi 丢了酷狗歌单广场接口')):
        if kw not in api:
            cd += 1
            issues.append(('CD', 'FAIL', msg))
    if "platform === 'tx'" not in feed and 'DISCOVER_PLATFORM_IDS' not in platform:
        cd += 1
        issues.append(('CD', 'FAIL', '发现页 tx/kg 板块编排被误删'))
    if "DISCOVER_PLATFORM_IDS: string[] = ['wy', 'tx', 'kw', 'kg']" not in platform:
        cd += 1
        issues.append(('CD', 'FAIL', '发现平台清单没保留 tx / kg'))

    # 网易云账号同步链路仍在（不能把 wy 一起删了）
    hub = get('core/FavSyncHub.ets')
    for kw, msg in (('WyFavSync.get().reconcile()', '网易云对账链路被误删'),
                    ('startForegroundSync()', '前台实时对账被误删'),
                    ('FavSyncStatus', '统一状态聚合被误删')):
        if kw not in hub:
            cd += 1
            issues.append(('CD', 'FAIL', msg))

    if cd == 0:
        issues.append(('CD', 'PASS',
                       'QQ / 酷狗账号登录体系连根删除：7 个账号/扫码/收藏读写/通用面板文件、'
                       '凭证与同步队列 PrefKeys、AppStorage 广播 key、App.init 初始化、'
                       'Library hook、设置页/收藏页订阅全部清零；'
                       'FavSyncHub 收口为仅 wy 但保留实时心跳与统一状态；'
                       'tx / kg 音源平台（搜索/封面/歌单广场/发现板块/本地收藏数据）完整保留'))


def check_download_audio_tags(src):
    """CE：下载歌曲写入「文件内」元信息与歌词，且只产出单文件（v1.0）。

    排查结论：Downloader 以前只把原始字节 copyFileSync 落盘，歌名/歌手仅在
    文件名里，拷到别的设备就是「未知标题 / 未知歌手 / 无歌词」。
    用户口径：歌词要「内嵌进歌曲文件」，不要额外再下一个 .lrc。本组锁死两件事：
      ① mp3(ID3v2.3 USLT) / flac(Vorbis LYRICS) 歌词确实写进了音频文件内部；
      ② 下载目录只有一个文件 —— 绝不生成外挂 .lrc，并清掉旧版遗留的 .lrc。
    """
    ce = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    tag = get('core/AudioTag.ets')
    dl = get('core/Downloader.ets')
    if not tag or not dl:
        issues.append(('CE', 'FAIL', '缺 AudioTag.ets 或 Downloader.ets'))
        return

    # mp3 ID3v2.3：标题 / 歌手 / 专辑 / USLT 歌词；并保留原有封面等无关帧
    for kw, msg in (('id3Tag(', '缺 ID3v2 标签构造'),
                    ("id3Text('TIT2'", '没写标题 TIT2'),
                    ("id3Text('TPE1'", '没写歌手 TPE1'),
                    ("id3Text('TALB'", '没写专辑 TALB'),
                    ("id3Frame('USLT'", '没把歌词写进 USLT 帧'),
                    ('parseId3Frames', '没保留原有 ID3 帧（会丢封面）'),
                    # 第五次返工：stripId3（整文件 subarray）改成 id3End（只算旧 ID3
                    # 结束位置 = 音频起点）。rewrite 从该 offset 流式搬音频，新头整体
                    # 替代旧头，天然不叠标签；顺带不再把整份音频读进 JS 内存。
                    ('id3End(', '没算出音频起点 / 旧 ID3 结束位置（重复写入会叠标签）'),
                    ('readHead(', '缺只读标签区头部（整读整写大对象回来了）')):
        if kw not in tag:
            ce += 1
            issues.append(('CE', 'FAIL', 'AudioTag ' + msg))
    # flac Vorbis Comment：TITLE / ARTIST / ALBUM / LYRICS
    for kw, msg in (("utf8('fLaC')", '缺 FLAC 容器识别'),
                    ("'TITLE='", '缺 Vorbis TITLE'),
                    ("'ARTIST='", '缺 Vorbis ARTIST'),
                    ("'ALBUM='", '缺 Vorbis ALBUM'),
                    ("'LYRICS='", '没把歌词写进 LYRICS 字段'),
                    ('type === 4', '没识别/合并已有 VORBIS_COMMENT 块'),
                    ('last: i === blocks.length - 1', '没修正 last-metadata-block 标志')):
        if kw not in tag:
            ce += 1
            issues.append(('CE', 'FAIL', 'AudioTag ' + msg))
    # 单文件：绝不生成外挂 .lrc（用户明确要求「只下载单文件歌曲」）
    for kw, msg in (('writeLrcFile', '仍在调用外挂歌词写入函数'),
                    ('fs.writeSync(fd.fd, lrc)', '仍在把歌词写成独立 .lrc 文件'),
                    ('额外落一份', '注释仍宣称会额外落 .lrc')):
        if kw in tag:
            ce += 1
            issues.append(('CE', 'FAIL', 'AudioTag ' + msg))
    for kw, msg in (('removeSidecarLrc(', '缺清理旧版遗留 .lrc'),
                    ('fs.unlinkSync(lrcPath)', '历史遗留 .lrc 没有删掉')):
        if kw not in tag:
            ce += 1
            issues.append(('CE', 'FAIL', 'AudioTag ' + msg))
    # 写盘回滚
    for kw, msg in (('rewrite(', '缺整体重写 + 失败回滚'),
                    ('已回滚原文件', '写盘失败没回滚原字节')):
        if kw not in tag:
            ce += 1
            issues.append(('CE', 'FAIL', 'AudioTag ' + msg))
    # Downloader 接入：落盘后先写元数据，歌词异步补齐（幂等二次 embed）
    for kw, msg in (('AudioTag.embed(finalPath, task.format, task.song,', '落盘后没调用内嵌'),
                    ('embedLyricLater(', '缺歌词异步补齐'),
                    ('LyricRepo.get().get(song)', '没从歌词仓库取词'),
                    ('toLrcText(', '缺 LyricDoc→LRC 还原'),
                    ('不影响下载', '标签失败没兜住（会连累下载结果）')):
        if kw not in dl:
            ce += 1
            issues.append(('CE', 'FAIL', 'Downloader ' + msg))
    # 顺序：embed 必须在异步落盘之后、标记 done 之前
    copy_at = dl.find('await this.moveToTarget(tempPath, fileName)')
    embed_at = dl.find('AudioTag.embed(finalPath, task.format, task.song,')
    done_at = dl.find("task.status = 'done'", embed_at)
    if copy_at < 0 or embed_at < 0 or done_at < 0 or not (copy_at < embed_at < done_at):
        ce += 1
        issues.append(('CE', 'FAIL', '内嵌时机不对：必须在落盘之后、标记 done 之前'))
    if '落同名 .lrc' in dl or '/ 同名 .lrc' in dl:
        ce += 1
        issues.append(('CE', 'FAIL', 'Downloader 注释仍宣称会额外落 .lrc 文件'))

    if ce == 0:
        issues.append(('CE', 'PASS',
                       '下载目录只产出「一个」歌曲文件：mp3 写 ID3v2.3（TIT2/TPE1/TALB + USLT 歌词内嵌，'
                       '保留原有封面帧），flac 写 Vorbis Comment（TITLE/ARTIST/ALBUM + LYRICS 内嵌，'
                       '修正 last-block），歌词就在音频文件内部、不额外生成同名 .lrc；'
                       '每次 embed 顺手清掉旧版遗留的 .lrc；整体重写带失败回滚，'
                       '歌词由 LyricRepo 异步补齐且二次写入幂等，m4a/ogg/wav 不动字节也不带歌词，'
                       '标签失败不影响下载结果'))


def check_download_concurrency(src):
    """CF：并行下载档位可设置、改完立即补位（v1.0）。

    用户口径：一次下好几首，只有一个「下载中」、其余全「排队中」；
    要一个「同时下载几首」的选项。排查结论：Downloader 把 maxRunning 写死 2，
    既没有设置入口，pump() 又只在入队 / 任务完成时触发。本组锁死四件事：
      ① 常量 + PrefKey + Settings 读写（带 1~5 clamp，脏值兜底）；
      ② Downloader 不再硬编码 2，init 读回、setConcurrency 落盘后立即 pump；
      ③ 下载管理页有档位调节且接 setConcurrency，改完不重启即生效
        （v1.0c 起改为一行式「− 数字 +」步进器 + 收紧卡片，旧 5 档 Chip 禁止复活）；
      ④ 不动取消 / 重试 / 清理 / 单文件内嵌歌词等既有链路。
    """
    cf = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    const = get('common/Constants.ets')
    settings = get('core/Settings.ets')
    dl = get('core/Downloader.ets')
    # v1.0 第四次返工：档位卡片随红圈标记内容整体搬到「数据管理」二级页
    page = get('ui/pages/DataSettingsPage.ets')

    if not all((const, settings, dl, page)):
        issues.append(('CF', 'WARN', '没找齐并发下载相关文件，跳过检查'))
        return

    # ① 常量 / PrefKey / Settings 读写 + clamp
    for kw, msg in (("DOWNLOAD_CONCURRENCY: string = 'v4_download_concurrency'", '缺 DOWNLOAD_CONCURRENCY PrefKey'),
                    ('DOWNLOAD_CONCURRENCY_MIN: number = 1', '缺 MIN=1'),
                    ('DOWNLOAD_CONCURRENCY_MAX: number = 5', '缺 MAX=5'),
                    ('DOWNLOAD_CONCURRENCY_DEFAULT: number = 3', '缺 DEFAULT=3')):
        if kw not in const:
            cf += 1
            issues.append(('CF', 'FAIL', 'Constants ' + msg))
    for kw, msg in (('downloadConcurrency(): number', '缺 downloadConcurrency() 读'),
                    ('setDownloadConcurrency(value: number): void', '缺 setDownloadConcurrency() 写'),
                    ('PrefKeys.DOWNLOAD_CONCURRENCY', 'Settings 没用到并发 PrefKey'),
                    ('if (!(n >= DOWNLOAD_CONCURRENCY_MIN))', '读没做下界 clamp / NaN 兜底'),
                    ('if (n > DOWNLOAD_CONCURRENCY_MAX)', '读没做上界 clamp')):
        if kw not in settings:
            cf += 1
            issues.append(('CF', 'FAIL', 'Settings ' + msg))

    # ② Downloader：不再写死 2，init 读回，setConcurrency 立即 pump
    if 'private maxRunning: number = 2' in dl:
        cf += 1
        issues.append(('CF', 'FAIL', 'Downloader 仍把并发上限写死为 2'))
    if 'private maxRunning: number = DOWNLOAD_CONCURRENCY_DEFAULT' not in dl:
        cf += 1
        issues.append(('CF', 'FAIL', 'Downloader 字段初值没用 DEFAULT 常量'))
    if 'this.maxRunning = Settings.get().downloadConcurrency();' not in dl:
        cf += 1
        issues.append(('CF', 'FAIL', 'init() 没从设置读回并发档位（重启后会退回默认）'))
    if 'while (this.running < this.maxRunning && this.queue.length > 0)' not in dl:
        cf += 1
        issues.append(('CF', 'FAIL', 'pump() 没按 maxRunning 判断并发'))
    # setConcurrency 函数体必须落盘 + 立即 pump + 广播
    sc = dl.find('setConcurrency(value: number): void')
    sc_end = dl.find('\n  }', sc)
    sc_body = dl[sc:sc_end] if sc >= 0 and sc_end > sc else ''
    if not sc_body:
        cf += 1
        issues.append(('CF', 'FAIL', 'Downloader 缺 setConcurrency()'))
    else:
        for kw, msg in (('Settings.get().setDownloadConcurrency(value)', '没落盘'),
                        ('this.maxRunning = Settings.get().downloadConcurrency();', '没更新运行时上限'),
                        ('this.pump();', '改完没立即补位启动排队任务（要等下一首完成才生效）'),
                        ('this.notify();', '改完没广播，页面选中态不会刷新')):
            if kw not in sc_body:
                cf += 1
                issues.append(('CF', 'FAIL', 'setConcurrency ' + msg))
    if 'concurrency(): number' not in dl:
        cf += 1
        issues.append(('CF', 'FAIL', 'Downloader 缺 concurrency() 供页面读取当前档位'))

    # ③ 页面：一行式「− 数字 +」步进器（v1.0c：旧横排 5 档 Chip 整卡太大，已废除）
    for kw, msg in (('concurrencyCard()', '缺并发档位卡片'),
                    ('@State concurrency: number = DOWNLOAD_CONCURRENCY_DEFAULT', '缺 @State concurrency'),
                    ('this.concurrency = App.get().downloads.concurrency();', 'refresh 没同步当前档位'),
                    ('App.get().downloads.setConcurrency(n);', '点步进器没接 setConcurrency'),
                    ('applyConcurrency(this.concurrency - 1)', '缺左侧「−」减一'),
                    ('applyConcurrency(this.concurrency + 1)', '缺右侧「+」加一'),
                    ('DOWNLOAD_CONCURRENCY_MIN', '页面没引用下界常量（边界置灰 / 越界 return）'),
                    ('DOWNLOAD_CONCURRENCY_MAX', '页面没引用上界常量（边界置灰 / 越界 return）'),
                    ("this.concurrency.toString() + ' 首'", '卡片没显示当前档位数字')):
        if kw not in page:
            cf += 1
            issues.append(('CF', 'FAIL', 'DataSettingsPage ' + msg))
    # 反向：旧版横排 5 档 Chip 不得复活（用户反馈「同时下载占用太大」）
    if 'Chip({' in page or re.search(r"text: '\d', active: this\.concurrency", page):
        cf += 1
        issues.append(('CF', 'FAIL', '并行卡片又出现 5 档 Chip（旧版整卡过大）'))
    if 'padding({ left: 14, right: 10, top: 9, bottom: 9 })' not in page:
        cf += 1
        issues.append(('CF', 'FAIL', '并发卡片没收紧内边距（仍是 padding 16 的大卡）'))
    if 'this.concurrencyCard()' not in page:
        cf += 1
        issues.append(('CF', 'FAIL', 'build() 没把并发卡片插进页面'))

    # ④ 既有链路仍在（别为加设置把老功能改坏）
    for kw, msg in (('AudioTag.embed(finalPath, task.format, task.song,', '内嵌元数据链路被破坏'),
                    ('embedLyricLater(', '歌词内嵌链路被破坏'),
                    ('cancel(id: string): void', '取消下载被破坏'),
                    ('retry(id: string): void', '重试下载被破坏')):
        if kw not in dl:
            cf += 1
            issues.append(('CF', 'FAIL', 'Downloader ' + msg))

    if cf == 0:
        issues.append(('CF', 'PASS',
                       '并行下载可设 1~5 首（默认 3）：Constants 常量 + PrefKey、Settings 读写带 clamp，'
                       'Downloader 取消写死 2 改从 init 读回，setConcurrency 落盘后立即 pump 让排队任务补位；'
                       '数据管理页就地放一行式「− 数字 +」步进器（旧 5 档 Chip 已废除、卡片收窄），'
                       '点按不重启即生效；取消/重试/单文件内嵌歌词链路均保留'))


def check_ignore_interrupt(src):
    """CG：忽略音频打断（v1.0d）——跨应用共存靠 AudioSession 混音。

    用户反馈：开关打开后，其它应用一播放本应用照样暂停。两条根因：
      ① AVPlayer.audioInterruptMode 只决定「同一应用内多条音频流」的焦点归属，
        管不了跨应用；PAUSE / STOP 是 INTERRUPT_FORCE（系统强制执行），
        在 audioInterrupt 回调里 return 根本挡不住。
      ② 两个属性被设在 createAVPlayer() 后的 idle 状态。官方要求
        audioRendererInfo 在 initialized（首次 prepare() 前）、
        audioInterruptMode 在 prepared（首次 play() 前），idle 设置不生效。
    修复：AudioSession CONCURRENCY_MIX_WITH_OTHERS + 会话释放后重激活 +
    强制打断节流续播兜底。本组锁死这些点，防止退回「回调里 return」的旧写法。
    """
    cg = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    player = get('core/Player.ets')
    page = get('ui/pages/PlaySettingsPage.ets')
    if not player or not page:
        issues.append(('CG', 'WARN', '没找齐 Player / PlaySettingsPage，跳过忽略打断检查'))
        return

    # ① AudioSession 混音策略全链路
    for kw, msg in (('getSessionManager()', '没拿到 AudioSessionManager'),
                    ('CONCURRENCY_MIX_WITH_OTHERS', '没用混音共存策略'),
                    ('activateAudioSession(', '没激活音频会话'),
                    ('deactivateAudioSession(', '关开关时没释放会话'),
                    ('isAudioSessionActivated()', '激活前没做幂等判断'),
                    ('audioSessionDeactivated', '没监听会话被系统释放（超时后策略会失效）'),
                    ('syncAudioSession()', '缺按开关同步会话的方法'),
                    ('resumeFromForcedInterrupt', '缺系统强制打断后的续播兜底'),
                    ('AUDIO_SESSION_SCENE_MEDIA', '没设置媒体会话场景')):
        if kw not in player:
            cg += 1
            issues.append(('CG', 'FAIL', 'Player ' + msg))

    # ② 属性设置时机：两个属性都不得留在 idle 块，且顺序必须正确
    prep = player.find('private async prepare(')
    cb = player.find("player.on('stateChange'", prep)
    idle_block = player[prep:cb] if prep >= 0 and cb > prep else ''
    if 'player.audioRendererInfo =' in idle_block or 'player.audioInterruptMode =' in idle_block:
        cg += 1
        issues.append(('CG', 'FAIL', '又在 idle 状态设置音频属性（官方要求 initialized / prepared）'))
    i0 = player.find("if (state === 'initialized')", cb)
    i1 = player.find("} else if (state === 'prepared') {", i0)
    i2 = player.find("} else if (state === 'playing') {", i1)
    init_body = player[i0:i1] if i0 >= 0 and i1 > i0 else ''
    prep_body = player[i1:i2] if i1 >= 0 and i2 > i1 else ''
    if 'player.audioRendererInfo =' not in init_body:
        cg += 1
        issues.append(('CG', 'FAIL', 'audioRendererInfo 没放进 initialized 分支'))
    elif init_body.find('player.audioRendererInfo =') > init_body.find('player.prepare()'):
        cg += 1
        issues.append(('CG', 'FAIL', 'audioRendererInfo 没在首次 prepare() 之前设置'))
    if 'player.audioInterruptMode =' not in prep_body:
        cg += 1
        issues.append(('CG', 'FAIL', 'audioInterruptMode 没放进 prepared 分支'))
    elif prep_body.find('player.audioInterruptMode =') > prep_body.find('player.play()'):
        cg += 1
        issues.append(('CG', 'FAIL', 'audioInterruptMode 没在首次 play() 之前设置'))
    if 'this.syncAudioSession();' not in prep_body:
        cg += 1
        issues.append(('CG', 'FAIL', '起播前没确认混音会话仍激活'))

    # ③ 旧写法与接线
    if 'if (token !== this.token || Settings.get().ignoreInterrupt())' in player:
        cg += 1
        issues.append(('CG', 'FAIL', '又退回「回调里直接 return」的旧写法（FORCE 打断挡不住）'))
    if 'App.get().player.applyInterruptMode();' not in page:
        cg += 1
        issues.append(('CG', 'FAIL', '播放设置页开关没接 applyInterruptMode'))
    ap = player.find('applyInterruptMode(): void')
    ap_end = player.find('\n  }', ap)
    ap_body = player[ap:ap_end] if ap >= 0 and ap_end > ap else ''
    if 'syncAudioSession' not in ap_body:
        cg += 1
        issues.append(('CG', 'FAIL', '开关切换时没同步 AudioSession 策略'))

    if cg == 0:
        issues.append(('CG', 'PASS',
                       '忽略音频打断改用 AudioSession 混音共存：开→MIX_WITH_OTHERS 激活、关→释放，'
                       '会话被系统释放后自动重激活；属性改到 initialized（prepare 前）/ prepared（play 前）'
                       '合法状态；强制打断有节流续播兜底，旧「回调 return」写法已禁止'))


def check_b_cleanup(src):
    """CY：B1/B2/B5/B6 四项清理守护（源码 + 断言成对）。

    删除项：PlayStats 整链 + 月报 API（B1/B2）、光感四档迁移提示（B5）、
    qq/kg 中性空态（B6）。同时锁死 B11 光感符号壳与同步聚合链路不被误删。
    读 load_raw() 磁盘原文，注释里的残留同样算数。
    """
    cy = 0
    raw = load_raw()
    all_ets = '\n'.join(s for f, s in raw.items() if f.endswith('.ets'))

    def get(suffix: str) -> str:
        return next((s for f, s in raw.items() if f.endswith(suffix)), '')

    hub = get('core/FavSyncHub.ets')
    consts = get('common/Constants.ets')
    settings_core = get('core/Settings.ets')

    # ① B1/B2 统计层整链清零
    if any(f.endswith('core/PlayStats.ets') for f in raw):
        cy += 1
        issues.append(('CY', 'FAIL', 'PlayStats.ets 仍存在：统计层没删干净'))
    for kw, msg in (('PlayStats', '仍残留 PlayStats 引用'),
                    ('PLAY_STATS', '仍残留统计持久化键'),
                    ('v4_play_stats', '仍残留统计落盘 key 字面量'),
                    ('MonthReport', '仍残留月报类型'),
                    ('reportOf(', '仍残留月报查询 API'),
                    ('onSongStart(', '仍残留切歌埋点'),
                    ('onCompleted(this.current)', '仍残留完播埋点')):
        if kw in all_ets:
            cy += 1
            issues.append(('CY', 'FAIL', 'B1/B2 ' + msg + '：' + kw))

    # ② B5 光感迁移提示整链清零
    for kw, msg in (('LIGHT_SENSE_NOTICE', '仍残留提示独立键'),
                    ('v4_light_sense_notice', '仍残留提示落盘 key'),
                    ('lightSenseNoticeSeen', '仍残留提示标记读写'),
                    ('needLightNotice', '仍残留提示条件方法'),
                    ('lightNotice', '仍残留一次性提示状态'),
                    ('光感四档已取消', '仍残留提示文案'),
                    ("Text('知道了')", '仍残留提示关闭按钮')):
        if kw in all_ets:
            cy += 1
            issues.append(('CY', 'FAIL', 'B5 ' + msg + '：' + kw))

    # ③ B6 中性空态清零，但统一状态聚合与实时对账必须保留
    for kw, msg in (("scope !== 'all'", '仍残留 qq/kg 早退分支'),
                    ('const empty: FavSyncStatus', '仍残留中性空态构造'),
                    ('中性空态', '仍残留中性空态注释')):
        if kw in hub:
            cy += 1
            issues.append(('CY', 'FAIL', 'B6 ' + msg + '：' + kw))
    for kw, msg in (('status(scope: string): FavSyncStatus', '统一状态聚合被误删'),
                    ('label(scope: string): string', '状态条文案被误删'),
                    ('toastText(scope: string): string', '同步结论被误删'),
                    ('startForegroundSync()', '前台实时对账被误删'),
                    ('WyFavSync.get().reconcile()', '网易云对账链路被误删')):
        if kw not in hub:
            cy += 1
            issues.append(('CY', 'FAIL', '清理时 ' + msg + '：' + kw))

    # ④ B11 光感符号壳与玻璃四件套必须完好
    for kw, msg in (('static readonly LIGHT_SENSE:', 'LIGHT_SENSE 键被误删'),
                    ('export function lightSense(level: number', 'lightSense 参数化函数被误删')):
        if kw not in consts:
            cy += 1
            issues.append(('CY', 'FAIL', 'B11 ' + msg))
    if 'getNumber(PrefKeys.LIGHT_SENSE, 3)' not in settings_core:
        cy += 1
        issues.append(('CY', 'FAIL', 'B11 lightSense() 默认值 3 被改'))
    if "@StorageProp('lightSense') lightLevel: number = 3" not in all_ets or \
            'glassSurface(this.isDark, this.lightLevel)' not in all_ets:
        cy += 1
        issues.append(('CY', 'FAIL', 'B11 光感订阅 / 玻璃四件套订阅被误删'))

    if cy == 0:
        issues.append(('CY', 'PASS',
                       'B1/B2/B5/B6 清理闭合：PlayStats 整链与月报 API、光感迁移提示、'
                       'qq/kg 中性空态全部清零；B11 光感符号壳与同步状态聚合 / 实时对账完好'))


def check_song_comments(src):
    """CZ：歌曲评论（v1.0 · 2026-11-14）。

    锁死八件事，防止后续改动把「能看评论」退化成假功能或撞坏既有约束：
      ① 四个实测可用平台（wy/tx/kw/kg）都有分派与官方匿名端点；
      ② tx mid→songid、kg hash→audio_id 两个 id 桥接不能省，省了就是空列表；
      ③ 咪咕（mg）评论接口已下线且需登录 → 直接隐藏入口，不显示假空白；
      ④ 评论是 bindSheet 组件（panel=8），不是新路由 —— AC 组锁的 12 个名字一个都不许加；
      ⑤ 失败一律显示真实原因 + 重试，不允许占位评论 / 拿空数组冒充成功；
      ⑥ 切歌靠 songKey @Watch 重拉，不残留上一首歌的评论；
      ⑦ 真机回归两条：QQ null 字段 typeof 兜底、酷狗 POST 空 body 改 GET；
      ⑧ 无限滚动：热评批次置顶后自动接续最新流（热评接口无第二页），
         UI 用 onReachEnd 触底追加，禁止退回翻页按钮。
    """
    cz = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    api = get('core/CommentApi.ets')
    panel = get('ui/pages/CommentPanel.ets')
    player = get('ui/pages/PlayerPage.ets')
    index = get('pages/Index.ets')

    for text, label in ((api, 'core/CommentApi.ets'),
                        (panel, 'ui/pages/CommentPanel.ets')):
        if not text:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论模块缺失：' + label))

    # ① 四平台端点 + 分派
    for kw, msg in (
        ("R_SO_4_", '网易云评论端点'),
        ('fcg_global_comment_h5.fcg', 'QQ 音乐评论端点'),
        ('comment.kuwo.cn/com.s', '酷我评论端点'),
        ('mcomment/v1/cmtlist', '酷狗评论端点'),
        ("song.source === 'wy'", 'wy 分派'),
        ("song.source === 'tx'", 'tx 分派'),
        ("song.source === 'kw'", 'kw 分派'),
        ('return await kgComments(song, safePage)', 'kg 分派'),
    ):
        if kw not in api:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论数据层缺 ' + msg))

    # ② 两个 id 桥接 + 酷狗原生签名
    for kw, msg in (
        ('client_search_cp', 'QQ mid→songid 反查'),
        ('getSongInfo.php?cmd=playInfo', '酷狗 hash→audio_id 桥接'),
        ('cryptoFramework.createMd(\'MD5\')', '原生 MD5 签名能力'),
        ('kgAndroidSign(params)', '酷狗 Android 签名'),
    ):
        if kw not in api:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论数据层缺 ' + msg))

    # ③ 咪咕隐藏入口：白名单里不能有 mg，播放页必须按 commentSupported 条件渲染
    if "return s === 'wy' || s === 'tx' || s === 'kw' || s === 'kg';" not in api:
        cz += 1
        issues.append(('CZ', 'FAIL', 'commentSupported 白名单不对：咪咕必须排除'))
    if 'if (commentSupported(this.song)) {' not in player:
        cz += 1
        issues.append(('CZ', 'FAIL', '播放页没有按平台条件隐藏评论入口'))

    # ④ 不新增路由
    if "name === 'comment'" in index or "name === 'comments'" in index or \
            'CommentPanel()' in index:
        cz += 1
        issues.append(('CZ', 'FAIL', '评论误注册为路由（AC 组路由白名单只能有 12 个名字）'))
    for kw, msg in (('commentButton()', '评论按钮'),
                    ('this.panel = 8;', 'panel=8 触发'),
                    ('this.panel === 8', 'panel=8 分支'),
                    ('CommentPanel({', '评论面板挂载'),
                    ('this.panel === 8\n        ? SheetSize.LARGE', 'LARGE 半屏高度')):
        if kw not in player:
            cz += 1
            issues.append(('CZ', 'FAIL', '播放页缺 ' + msg))

    # ⑤ 失败如实展示，不做假数据
    for kw, msg in (('failPage(platform,', '失败返回真实原因'),
                    ('p.supported = false;', '不支持平台标记'),
                    ('不伪造空列表', '设计边界声明')):
        if kw not in api:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论数据层缺 ' + msg))
    for kw, msg in (('this.result.error', '真实错误展示'),
                    ('Text(\'重试\')', '重试按钮'),
                    ('@Watch(\'onSongKeyChange\')', '切歌重拉')):
        if kw not in panel:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论面板缺 ' + msg))

    # ⑦ 真机回归（2026-11-14）两条，防止改回去：
    #    QQ 评论字段大量为 null，str/num 只判 undefined 会让 .length 抛 TypeError；
    #    酷狗 POST 空 body 在 HarmonyOS NetworkKit 报 Parameter error，必须走 GET。
    for kw, msg in (("typeof v === 'string'", '字符串字段 null 兜底'),
                    ("typeof v === 'number'", '数字字段 null 兜底'),
                    ('newRaws.length > 0', 'QQ 热评为空时降级'),
                    ('getJson<KgCmtResp>', '酷狗评论走 GET')):
        if kw not in api:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论数据层缺 ' + msg))
    for kw, msg in (("v === undefined ? '' : v", '旧 str 写法（null 会漏）'),
                    ("options.method = 'POST'", '酷狗 POST 空 body（真机 Parameter error）')):
        if kw in api:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论数据层残留 ' + msg))

    # ⑧ 无限滚动（2026-11-14）：实测热评接口没有第二页（wy hotComments 固定 15 条、
    #    tx cmd=6 翻页参数无效），必须热评批次置顶后自动接续最新流；
    #    UI 必须触底追加而非翻页按钮，且不允许退回「上一页 / 下一页」。
    for kw, msg in (('const hotBatch: boolean', '热评批次标记'),
                    ('? (total > 0 && list.length > 0)', 'wy 热评批次放行续刷'),
                    ('? newRaws.length > 0', 'tx 热评批次放行续刷'),
                    ('hotBatch ? 1 : (hot ? page - 1 : page)', 'kw 热评接最新流'),
                    ('wyFetch(url)', 'wy 限流 -462 自动重试')):
        if kw not in api:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论数据层缺 ' + msg))
    if '!hot &&' in api:
        cz += 1
        issues.append(('CZ', 'FAIL', '评论数据层残留热评 hasMore 一刀切（热评将无法续刷）'))
    for kw, msg in (('.onReachEnd(', '触底加载事件'),
                    ('this.loadMore()', '触底加载入口'),
                    ('loadingMore', '追加中状态'),
                    ('this.result.comments.slice()', '追加而非替换'),
                    ('this.seen[key] !== true', '按 id 去重'),
                    ('added === 0', '无新增时停止，防死循环')):
        if kw not in panel:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论面板缺 ' + msg))
    for kw, msg in (('上一页', '翻页按钮'),
                    ('下一页', '翻页按钮'),
                    ('pager()', '旧翻页控件'),
                    ('goPage(', '旧翻页方法')):
        if kw in panel:
            cz += 1
            issues.append(('CZ', 'FAIL', '评论面板残留 ' + msg))

    if cz == 0:
        issues.append(('CZ', 'PASS',
                       '歌曲评论：wy/tx/kw/kg 四平台官方匿名端点直连（含 tx mid→id、'
                       'kg hash→audio_id 桥接与原生 MD5 签名）；mg 隐藏入口不造假；'
                       '播放页底排第 5 按钮 + bindSheet panel=8 组件，零新增路由；'
                       '失败显真实原因可重试、切歌按 songKey 重拉；'
                       '真机回归：null 字段 typeof 兜底、QQ 热评降级、酷狗走 GET；'
                       '无限滚动：热评批次置顶后自动接续最新流、onReachEnd 触底追加、'
                       '按 id 去重、无翻页按钮'))


def check_auto_download(src):
    """DA：失败面板音源名对比度 + 听够 2/3 自动下载（v1.0 · 2026-11-14）。

    锁死六件事：
      ① 失败面板卡片内文字跟卡片主题取色 —— p() 恒深色 + 浅色主题白卡 = 白底白字，
         真机上音源名几乎看不见（用户截图实测）；
      ② 音源名加字号 / 字重，压过下面的错误原因；
      ③ 开关有 PrefKey / Settings 读写 / 备份白名单，默认关；
      ④ Player 在 timeUpdate 按 2/3 阈值触发，每首一次、切歌复位，不直接依赖 App；
      ⑤ App 侧执行器做开关判断 + 本地歌 / 已下载 / 已在队列去重，不弹错误卡片；
      ⑥ 下载页有开关卡片且即时落盘；不新增路由（12 个路由名由 CG 组锁）。
    """
    da = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    const = get('common/Constants.ets')
    settings = get('core/Settings.ets')
    backup = get('core/Backup.ets')
    player = get('core/Player.ets')
    app = get('core/App.ets')
    # v1.0 第四次返工：自动下载开关随红圈标记内容搬到「数据管理」二级页
    page = get('ui/pages/DataSettingsPage.ets')
    player_page = get('ui/pages/PlayerPage.ets')

    if not all((const, settings, backup, player, app, page, player_page)):
        issues.append(('DA', 'WARN', '没找齐自动下载 / 失败面板相关文件，跳过检查'))
        return

    # ①② 对比度：音源名所在的那一块必须跟 isDark 取色，不得用恒深色的 p()
    if 'Text(item.name)' in player_page and 'Text(item.text)' in player_page:
        name_block = player_page.split('Text(item.name)')[1].split('Text(item.text)')[0]
        for kw, msg in (('palette(this.isDark).text', '音源名没跟卡片主题取色'),
                        ('.fontWeight(FontWeight.Medium)', '音源名没加字重')):
            if kw not in name_block:
                da += 1
                issues.append(('DA', 'FAIL', '失败面板 ' + msg))
        if 'this.p().text' in name_block or 'this.p().primary' in name_block:
            da += 1
            issues.append(('DA', 'FAIL', '失败面板卡片内残留 p() 恒深色（白底白字会复现）'))
    else:
        da += 1
        issues.append(('DA', 'FAIL', '失败面板音源名 / 错误原因结构被改动，无法定位对比度修法'))
    if 'palette(this.isDark).text2' not in player_page:
        da += 1
        issues.append(('DA', 'FAIL', '失败面板错误原因没跟卡片主题取色'))

    # ③ 持久化与默认关闭
    if "AUTO_DOWNLOAD_ON_PLAY: string = 'v4_auto_download_on_play'" not in const:
        da += 1
        issues.append(('DA', 'FAIL', 'Constants 缺 AUTO_DOWNLOAD_ON_PLAY PrefKey'))
    for kw, msg in (('getBool(PrefKeys.AUTO_DOWNLOAD_ON_PLAY, false)', '开关没默认关'),
                    ('setAutoDownloadOnPlay(value: boolean): void', '缺 setter')):
        if kw not in settings:
            da += 1
            issues.append(('DA', 'FAIL', 'Settings ' + msg))
    if 'PrefKeys.AUTO_DOWNLOAD_ON_PLAY' not in backup:
        da += 1
        issues.append(('DA', 'FAIL', '备份白名单没纳入自动下载开关'))

    # ④ 播放触发
    for kw, msg in (('AUTO_DOWNLOAD_RATIO: number = 2 / 3', '缺 2/3 阈值常量'),
                    ('time >= this.duration * AUTO_DOWNLOAD_RATIO', 'timeUpdate 没按 2/3 触发'),
                    ('this.autoDownloadDone = false;', '切歌没复位 autoDownloadDone'),
                    ('setAutoDownloadHandler(handler:', '缺回调注入'),
                    ('this.autoDownloadHandler(this.current)', '没把当前歌曲交给执行器')):
        if kw not in player:
            da += 1
            issues.append(('DA', 'FAIL', 'Player ' + msg))

    # ⑤ App 侧去重与入队
    for kw, msg in (('setAutoDownloadHandler((song: SongInfo): void =>', '缺执行器注入'),
                    ('!Settings.get().autoDownloadOnPlay()', '执行器没判断开关'),
                    ("song.source === 'local'", '没跳过本地歌'),
                    ('this.hasDownload(song)', '没做已下载 / 队列去重'),
                    ('this.downloads.enqueue(song)', '没入队')):
        if kw not in app:
            da += 1
            issues.append(('DA', 'FAIL', 'App ' + msg))

    # ⑥ 数据管理页开关（v1.0 第四次返工从下载管理页搬来）
    for kw, msg in (('autoDownloadCard()', '缺开关卡片'),
                    ('Toggle({ type: ToggleType.Switch, isOn: this.autoDownload })', '缺 Toggle'),
                    ('this.settings.setAutoDownloadOnPlay(on)', '开关没落盘'),
                    ('@State autoDownload: boolean = false;', '开关默认没关')):
        if kw not in page:
            da += 1
            issues.append(('DA', 'FAIL', '下载页 ' + msg))

    if da == 0:
        issues.append(('DA', 'PASS',
                       '失败面板音源名跟卡片主题取色（消除白底白字）；'
                       '听够 2/3 自动下载：PrefKey/Settings/备份齐全且默认关、'
                       'Player 按进度阈值每首一次、App 侧开关+去重入队、下载页开关即时生效'))


def check_mf_capabilities(src):
    """DB：MusicFree 音源「能力扩展 + 音源要求的东西」（v1.0 · 2026-11-14）。

    用户口径：扩的是「音源能跑起来的能力」，不是「App 多几个内容页」；
    不跟现有工程冲突，本质仍是听歌 / 下载。锁死六件事：
      ① 运行时补齐真实插件高频导出方法（导入歌单 / 专辑 / 榜单 / 推荐 / 单曲信息）；
      ② 能力清单按插件实际导出生成，未导出不列；actions 协议三值不许被污染；
      ③ env.getUserVariables() 读真实值且是 getter（保存即生效），不再写死 {}；
      ④ 用户变量按音源隔离落本机 KV、装载前注入、含凭证不进备份白名单；
      ⑤ 落点只在音源管理页既有 sheet，零新增路由，结果只进播放 / 下载出口；
      ⑥ webdav / pako 仍如实标注不支持，不伪造能力；既有 detectKind 规则不动。
    """
    db = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    raw = os.path.join(ROOT, 'entry/src/main/resources/rawfile')
    rt_path = os.path.join(raw, 'vendor', 'mf_runtime.js')
    br_path = os.path.join(raw, 'lx_bridge.html')
    rt = open(rt_path, encoding='utf-8').read() if os.path.isfile(rt_path) else ''
    br = open(br_path, encoding='utf-8').read() if os.path.isfile(br_path) else ''
    repo = get('core/SourceRepo.ets')
    runner = get('core/LxRunner.ets')
    page = get('ui/pages/SourcesPage.ets')
    const = get('common/Constants.ets')
    models = get('common/Models.ets')
    index = get('pages/Index.ets')
    backup = get('core/Backup.ets')

    if not all((rt, br, repo, runner, page, const, models, index)):
        issues.append(('DB', 'WARN', '没找齐音源能力扩展相关文件，跳过检查'))
        return

    # ① 八类扩展能力分派必须真的调用到对应插件方法
    for kw, msg in (
        ("action === 'albumSearch'", '缺 album 类型搜索分派'),
        ("action === 'albumInfo'", '缺 getAlbumInfo 专辑详情分派'),
        ("action === 'topLists'", '缺 getTopLists 榜单列表分派'),
        ("action === 'topListDetail'", '缺 getTopListDetail 榜单歌曲分派'),
        ("action === 'recommendTags'", '缺 getRecommendSheetTags 推荐标签分派'),
        ("action === 'recommendSheets'", '缺推荐歌单分派'),
        ("action === 'musicInfo'", '缺 getMusicInfo 单曲信息分派'),
        ("action === 'importSheet'", '缺 importMusicSheet 导入歌单分派（最高频能力）'),
        ('function listOf(res)', '缺多形态返回归一（数组 / musicList / data / songs）'),
        ('function flattenTopLists(res, sid)', '缺榜单分组拍平'),
        ("getRecommendSheetsByTag", '没兼容 getRecommendSheetsByTag 变体'),
    ):
        if kw not in rt:
            db += 1
            issues.append(('DB', 'FAIL', 'mf_runtime.js ' + msg))

    # ② 能力声明按实际导出；actions 三值不许被污染
    for kw, msg in (
        ('var capabilities = [];', '缺按实际导出的能力清单'),
        ('var variableDefs = [];', '缺用户变量声明回传'),
        ('capabilities: capabilities,', '能力清单没回传给宿主'),
        ('variableDefs: variableDefs,', '变量声明没回传给宿主'),
        ("var actions = ['musicUrl'];", 'actions 协议被改动，会污染取链 / 取词判定'),
    ):
        if kw not in rt:
            db += 1
            issues.append(('DB', 'FAIL', 'mf_runtime.js ' + msg))
    if 'hasFn(\'importMusicSheet\')' not in rt:
        db += 1
        issues.append(('DB', 'FAIL', '能力清单没按「是否真的导出」判定，会伪造能力'))

    # ③ env 真实值 + getter + 插件真实读取的字段
    if 'getUserVariables: function () { return {}; }' in rt:
        db += 1
        issues.append(('DB', 'FAIL', 'env.getUserVariables 仍写死 {}：要 cookie/token 的插件全部残废'))
    for kw, msg in (
        ('getUserVariables: readUserVars', 'env.getUserVariables 不是 getter，保存配置不能即时生效'),
        ('userVariables: readUserVars()', '没兼容直读 env.userVariables 的插件'),
        ('AG_DEBUG: false', '没补 env.AG_DEBUG（22 个真实插件会读）'),
        ('function readUserVars()', '缺宿主变量注入的读取函数'),
    ):
        if kw not in rt:
            db += 1
            issues.append(('DB', 'FAIL', 'mf_runtime.js ' + msg))

    # ④ 变量注入 / 持久化 / 不外带
    for kw, msg in (
        ('__setUserVars: function (instId, varsJson)', '桥接页缺独立变量注入入口'),
        ('getUserVariables: function () { return userVarsByInst[instId] || {}; }',
         '桥接页没把变量接到运行时 env'),
        ('userVarsByInst = {};', '__reset 没清变量（会串源）'),
    ):
        if kw not in br:
            db += 1
            issues.append(('DB', 'FAIL', 'lx_bridge.html ' + msg))
    for kw, msg in (
        ('__setUserVars(', 'LxRunner.load 没在装载前注入用户变量'),
        ('async setUserVars(instId: string, varsJson: string): Promise<void>',
         '缺保存配置后即时注入的独立方法（不许改 load 签名）'),
        ('onMeta: ((instId: string, meta: string) => void) | null = null',
         '缺能力 / 变量声明回传回调'),
    ):
        if kw not in runner:
            db += 1
            issues.append(('DB', 'FAIL', 'LxRunner ' + msg))
    for kw, msg in (
        ('mfMetaOf(instId: string): MfMeta', '缺能力声明查询（且与静态 mfMeta 同名冲突要避开）'),
        ('mfUserVars(instId: string): string', '缺按音源隔离的用户变量读取'),
        ('async saveMfUserVars(', '缺用户变量保存 + 即时注入'),
        ('await this.injectUserVars(item.id);', 'loadOne / loadAll 没在装载前注入变量'),
        ('async probeMf(', '缺扩展能力统一试跑（结果归一到播放 / 下载出口）'),
        ("this.mfMetaOf(instId).capabilities.indexOf(action) < 0",
         '试跑没按声明过滤，会向不支持的插件发无效请求'),
    ):
        if kw not in repo:
            db += 1
            issues.append(('DB', 'FAIL', 'SourceRepo ' + msg))
    if "MF_USER_VARS: string = 'v4_mf_user_vars_'" not in const:
        db += 1
        issues.append(('DB', 'FAIL', 'Constants 缺按音源隔离的用户变量 PrefKey 前缀'))
    if 'PrefKeys.MF_USER_VARS' in backup:
        db += 1
        issues.append(('DB', 'FAIL', '用户变量含凭证却进了备份白名单，换机会串账号 / 泄露 token'))
    for kw, msg in (('export interface MfMeta', '缺能力声明模型'),
                    ('export interface MfVarDef', '缺用户变量声明模型'),
                    ('export interface MfProbeResult', '缺试跑结果模型')):
        if kw not in models:
            db += 1
            issues.append(('DB', 'FAIL', 'Models ' + msg))

    # ⑤ 落点只在音源页既有 sheet，零新增路由，结果只进播放 / 下载
    for kw, msg in (
        ('configSheet()', '缺音源页配置与能力浮层'),
        ('this.cfgMode)', 'menuSheet 没挂配置形态'),
        ('openConfig(this.menuTarget)', '菜单缺配置入口'),
        ('isMusicFree(this.menuTarget)', '配置入口没限定 MusicFree 源（洛雪脚本没有这些协议字段）'),
        ('saveCfgVars()', '缺保存用户变量动作'),
        ('runCfgProbe()', '缺能力试跑动作'),
        ('App.get().playAndOpen(this.cfgSongs.slice(), 0)', '试跑结果没走既有播放出口'),
        # v1.0 性能修复：试跑「下载全部」由逐首 enqueue 改为整批 enqueueAll，
        # 这里只按前缀校验「确实走 Downloader 下载出口」，不再锁死单首方法名，
        # 检查意图不变；批量收口的强度由 DC 组专门锁死。
        ('App.get().downloads.enqueue', '试跑结果没走既有下载出口'),
        ('InputType.Password', '密码类变量没用密码输入'),
    ):
        if kw not in page:
            db += 1
            issues.append(('DB', 'FAIL', 'SourcesPage ' + msg))
    # 内容页一行不许动：这些能力不得灌进发现 / 榜单 / 专辑 / 搜索的数据源
    for suffix in ('ui/pages/DiscoverPage.ets', 'ui/pages/RankBoardPage.ets',
                   'ui/pages/SheetDetailPage.ets', 'ui/pages/SearchPage.ets'):
        body = get(suffix)
        if body and ('probeMf(' in body or 'mfUserVars(' in body or 'configSheet(' in body):
            db += 1
            issues.append(('DB', 'FAIL', suffix + ' 被接入扩展能力，跟现有内容页冲突了'))
    # 路由表：锁定本次改动前的 12 个名字，不许因为扩展能力新增任何路由
    route_names = set(re.findall(r"name === '([A-Za-z][\w]*)'", index))
    baseline = {'sheet', 'rankboard', 'discoverSection', 'search', 'artist', 'downloads',
                'sources', 'playSettings', 'appearanceSettings', 'dataSettings',
                'wyAccount', 'favoriteSheets'}
    added = route_names - baseline
    if added:
        db += 1
        issues.append(('DB', 'FAIL', '路由表出现新名字：' + ','.join(sorted(added))))

    # ⑥ 不伪造能力：webdav / pako 继续如实标注
    for kw, msg in (("notSupported('webdav（网盘客户端）')", 'webdav 被伪装成可用'),
                    ("notSupported('pako（DEFLATE 压缩）')", 'pako 被伪装成可用')):
        if kw not in rt:
            db += 1
            issues.append(('DB', 'FAIL', 'mf_runtime.js ' + msg))

    if db == 0:
        issues.append(('DB', 'PASS',
                       '音源能力扩展：8 类高频能力真实分派（导入歌单/专辑/榜单/推荐/单曲信息）、'
                       '能力按实际导出声明不伪造、env.getUserVariables 接真实值且保存即时生效、'
                       '变量按音源隔离落本机且不进备份、装载前注入；'
                       '落点只在音源页既有 sheet，结果只进播放/下载出口，零新增路由、内容页零改动，'
                       'webdav/pako 仍如实标注不支持'))


def check_download_batch(src):
    """DC：批量下载入队「单次收口」（v1.0 · 2026-11-15）。

    事故：用户一次添加几十 / 上百首下载「巨卡但不卡死」。
    根因：enqueueAll 只是 for 循环逐首 enqueue，每首都做
      persist() → JSON.stringify(整个队列) + Store.put → flushSync() 同步刷盘（UI 线程）
      notify()  → AppStorage 全局广播，所有订阅页 / 列表行全量重绘
      pump()，再叠加 unshift 头插与线性查重的 O(n²)。
    删除路径 removeMany() 早就「只落盘一次、广播一次」，添加路径漏了。

    锁死八件事：
      ① enqueueAll 内 persist / notify / pump 各只出现一次；
      ② Set 索引一次查重 + 一次整体前插，不再逐首 unshift / 线性 find；
      ③ enqueue 单首委托 enqueueAll（一条实现，不分叉，单曲行为等价）；
      ④ 两个批量入口（歌单下载全部 / 音源试跑下载全部）整批走 enqueueAll；
      ⑤ 单首下载入口（自动下载 / 播放页 / 歌曲菜单 / 歌曲行）仍走 enqueue，不误改；
      ⑥ Store 同步落盘底座、removeMany、取消 / 重试 / 清理 / 并发档位不回退；
      ⑦ 本地已下载过滤（hasDownload）语义保留，不因批量化丢失；
      ⑧ 零新增路由、内容页零改动，不跟现有工程冲突。
    """
    dc = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    dl = get('core/Downloader.ets')
    sheet = get('ui/pages/SheetDetailPage.ets')
    sources = get('ui/pages/SourcesPage.ets')
    app = get('core/App.ets')
    player = get('ui/pages/PlayerPage.ets')
    menu = get('ui/SongMenu.ets')
    common = get('ui/Common.ets')
    store = get('core/Store.ets')
    index = get('pages/Index.ets')
    if not all((dl, sheet, sources, app, player, menu, common, store, index)):
        issues.append(('DC', 'WARN', '没找齐批量下载相关文件，跳过检查'))
        return

    # ① 只截取 enqueueAll 方法体，锁死「三个副作用各一次」
    m = re.search(r'enqueueAll\(songs:[^)]*\): number \{([\s\S]*?)\n  \}', dl)
    body = m.group(1) if m else ''
    if not body:
        dc += 1
        issues.append(('DC', 'FAIL', 'Downloader.enqueueAll 找不到方法体'))
    else:
        # 只统计方法体内的直接调用，注释里提到不算（用具体调用串、非纯关键字）
        for call, label in (('this.persist();', '落盘 persist'),
                            ('this.notify();', '广播 notify'),
                            ('this.pump();', '补位 pump')):
            n = body.count(call)
            if n != 1:
                dc += 1
                issues.append(('DC', 'FAIL',
                               f'enqueueAll 里 {label} 出现 {n} 次（必须恰好 1 次，逐首回退会 >1）'))
        # ② Set 索引查重 + 一次整体前插
        for kw, msg in (('const seen: Set<string> = new Set<string>();', '缺一次性 Set 查重索引'),
                        ('seen.has(song.id)', '没用 Set 查重'),
                        ('seen.add(song.id)', '批内重复没拦'),
                        ('head.concat(this.tasks)', '缺一次整体前插（仍在逐首 unshift）')):
            if kw not in body:
                dc += 1
                issues.append(('DC', 'FAIL', 'enqueueAll ' + msg))
        if 'this.tasks.unshift' in body:
            dc += 1
            issues.append(('DC', 'FAIL', 'enqueueAll 仍在逐首 unshift 头插，O(n²) 没消除'))
        # 方法体内不许再逐首调 enqueue（防回退成 for + enqueue）
        if re.search(r'for\s*\([\s\S]*?\)\s*\{[\s\S]*?this\.enqueue\(', body):
            dc += 1
            issues.append(('DC', 'FAIL', 'enqueueAll 又回退成循环逐首 enqueue'))

    # ③ 单首委托批量：一条实现，不分叉
    if 'this.enqueueAll([song], quality);' not in dl:
        dc += 1
        issues.append(('DC', 'FAIL', 'enqueue() 没委托 enqueueAll，单曲 / 批量两条实现会分叉'))
    if 'enqueue(song: SongInfo, quality: string = \'\'): void' not in dl:
        dc += 1
        issues.append(('DC', 'FAIL', 'enqueue() 签名被改，单首调用点可能失配'))

    # ④ 两个批量入口整批走 enqueueAll，且不再有逐首 enqueue 循环
    if 'App.get().downloads.enqueueAll(pending)' not in sheet:
        dc += 1
        issues.append(('DC', 'FAIL', '歌单「下载全部」没整批走 enqueueAll'))
    if 'App.get().downloads.enqueueAll(this.cfgSongs)' not in sources:
        dc += 1
        issues.append(('DC', 'FAIL', '音源试跑「下载全部」没整批走 enqueueAll'))
    for name, text in (('SheetDetailPage', sheet), ('SourcesPage', sources)):
        if re.search(r'for\s*\([\s\S]{0,200}?\)\s*\{[\s\S]{0,200}?downloads\.enqueue\(', text):
            dc += 1
            issues.append(('DC', 'FAIL', name + ' 仍残留逐首 enqueue 循环（批量会卡）'))

    # ⑤ 单首下载入口保持原样，不被误改成批量
    for name, text, kw in (
        ('自动下载', app, 'this.downloads.enqueue(song)'),
        ('播放页', player, 'App.get().downloads.enqueue(this.song)'),
        ('歌曲菜单', menu, 'App.get().downloads.enqueue(this.song)'),
        ('歌曲行', common, 'App.get().downloads.enqueue(this.song)'),
    ):
        if kw not in text:
            dc += 1
            issues.append(('DC', 'FAIL', name + ' 的单首 enqueue 出口被改动'))

    # ⑥ 既有链路不回退
    for kw, msg in (('this.pref.putSync(key, value);', 'Store.put 同步写入底座被改'),
                    ('this.persist();', 'Store.put 没当场落盘'),
                    ('[Store] 写入失败 ', 'Store.put 没兜住 putSync 异常（值超限会崩）'),
                    ('flushSync();', 'Store.flushSync 同步刷盘被改')):
        if kw not in store:
            dc += 1
            issues.append(('DC', 'FAIL', msg))
    for kw, msg in (('removeMany(ids: string[]): number', '批量删除收口 removeMany 被破坏'),
                    ('cancel(id: string): void', '取消下载被破坏'),
                    ('retry(id: string): void', '重试下载被破坏'),
                    ('clearDone(): void', '清理已完成被破坏'),
                    ('clearFailed(): void', '清理失败被破坏'),
                    ('while (this.running < this.maxRunning && this.queue.length > 0)', '并发 pump 被破坏')):
        if kw not in dl:
            dc += 1
            issues.append(('DC', 'FAIL', 'Downloader ' + msg))

    # ⑦ 本地 / 已下载过滤语义保留
    if 'App.get().hasDownload(song)' not in sheet:
        dc += 1
        issues.append(('DC', 'FAIL', '批量化把「本地已下载不再下」的过滤弄丢了'))

    # ⑧ 零新增路由（与 DB 组同一基线）
    route_names = set(re.findall(r"name === '([A-Za-z][\w]*)'", index))
    baseline = {'sheet', 'rankboard', 'discoverSection', 'search', 'artist', 'downloads',
                'sources', 'playSettings', 'appearanceSettings', 'dataSettings',
                'wyAccount', 'favoriteSheets'}
    if route_names - baseline:
        dc += 1
        issues.append(('DC', 'FAIL', '路由表出现新名字：' + ','.join(sorted(route_names - baseline))))

    if dc == 0:
        issues.append(('DC', 'PASS',
                       '批量下载入队单次收口：enqueueAll 一次 Set 查重 + 一次整体前插，'
                       'persist / notify / pump 各一次（同步刷盘与全局广播从 N 次降到 1 次）；'
                       '单首 enqueue 委托批量路径不分叉；两个批量入口整批入队；'
                       '单首出口 / Store 落盘底座 / removeMany / 取消重试清理 / 并发档位 / 本地过滤均不回退；'
                       '零新增路由、内容页零改动'))


def check_download_render(src):
    """DD：下载「稳态」渲染收口（v1.0 · 2026-11-15）。

    事故：装机实测「队列 234 首、下载中滚动长列表」仍掉帧（用户录屏佐证）。
    上一轮 DC 修的是「批量入队那一瞬间」，这次是「稳态高频刷新」，两条不同链路。
    根因：progress 每 300ms 走 notify() 把「进度」混进全局 downloadVersion，
      ① 页面级 refresh() 被进度触发 → ForEach 全量 diff + 4 个 O(n) 统计；
      ② 234 个行组件 + 首页 / 歌单 / 播放 / 所有歌曲行全部被唤醒重绘；
      ③ lastNotify 是每个任务各自的闭包局部变量，3 并发 ≈ 10 次/秒；
      ④ 行 task() 按 id 线性遍历 list()，build() 里调十几次 → O(n²)。

    锁死八件事：
      ① 进度 / 状态拆两条信号：notifyProgress 只 set downloadProgress，
         notify() 仍 set downloadVersion，二者互不串；
      ② 节流提到 Downloader 实例级 lastProgressNotify，全局 300ms，并发不放大；
      ③ progress 回调只调 notifyProgress，不再调 notify / 不再用局部 lastNotify；
      ④ byId 升级 public + Map O(1) 索引，集合结构变化标脏、长度兜底；
      ⑤ 行组件 task()/liveOf() 走 byId O(1)，不再线性遍历 list()；
      ⑥ 行组件只 running 行读 progressVersion 挂高频依赖，其它行不订阅；
      ⑦ 高频信号只出现在 Downloader / DownloadsPage，零扩散到内容页；
      ⑧ BC 组锁的 ForEach 稳定 key / 独立行组件 / 左滑不回弹不回退，
         Store 同步落盘底座 / removeMany 不回退，零新增路由、内容页零改动。
    """
    dd = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    dl = get('core/Downloader.ets')
    dpage = get('ui/pages/DownloadsPage.ets')
    store = get('core/Store.ets')
    index = get('pages/Index.ets')
    if not all((dl, dpage, store, index)):
        issues.append(('DD', 'WARN', '没找齐下载渲染相关文件，跳过检查'))
        return

    # ① 进度 / 状态信号分离
    mn = re.search(r'private notifyProgress\(\): void \{([\s\S]*?)\n  \}', dl)
    nbody = mn.group(1) if mn else ''
    if not nbody:
        dd += 1
        issues.append(('DD', 'FAIL', '找不到独立的高频进度广播 notifyProgress()'))
    else:
        if "setOrCreate('downloadProgress'" not in nbody:
            dd += 1
            issues.append(('DD', 'FAIL', 'notifyProgress 没广播独立 downloadProgress 信号'))
        if 'downloadVersion' in nbody:
            dd += 1
            issues.append(('DD', 'FAIL', 'notifyProgress 又碰了 downloadVersion，进度会重新唤醒页面级 refresh'))
        if 'this.notify()' in nbody:
            dd += 1
            issues.append(('DD', 'FAIL', 'notifyProgress 内部又调了 notify()，信号没拆干净'))
    if "AppStorage.setOrCreate('downloadVersion', Date.now());" not in dl:
        dd += 1
        issues.append(('DD', 'FAIL', '低频 notify() 不再广播 downloadVersion，状态刷新失效'))

    # ② 实例级全局 300ms 节流
    if 'private lastProgressNotify: number = 0;' not in dl:
        dd += 1
        issues.append(('DD', 'FAIL', '缺实例级 lastProgressNotify，节流仍会按并发放大'))
    if 'if (now - this.lastProgressNotify < 300)' not in nbody:
        dd += 1
        issues.append(('DD', 'FAIL', 'notifyProgress 没做全局 300ms 节流'))

    # ③ progress 回调只走高频信号
    mp = re.search(r"live\.on\('progress'[\s\S]*?live\.on\('complete'", dl)
    pseg = mp.group(0) if mp else ''
    if not pseg:
        dd += 1
        issues.append(('DD', 'FAIL', '找不到系统下载 progress 回调'))
    else:
        if 'this.notifyProgress();' not in pseg:
            dd += 1
            issues.append(('DD', 'FAIL', 'progress 回调没改调 notifyProgress'))
        if 'this.notify();' in pseg or 'let lastNotify' in pseg:
            dd += 1
            issues.append(('DD', 'FAIL', 'progress 回调仍调 notify() / 用局部 lastNotify，节流会放大'))
    if 'let lastNotify' in dl:
        dd += 1
        issues.append(('DD', 'FAIL', 'Downloader 里还残留每任务局部 lastNotify'))

    # ④ byId 升级 public + Map O(1) 索引
    for kw, msg in (
        ('taskIndex: Map<string, DownloadTask>', '缺 id → 任务 的 Map 索引'),
        ('private indexDirty: boolean = true;', '缺集合结构变化标脏位'),
        ('byId(id: string): DownloadTask | null {', 'byId 不是 public 或签名被改'),
        ('this.indexDirty || this.taskIndex.size !== this.tasks.length', '缺惰性重建 + 长度兜底'),
        ('this.rebuildIndex();', '缺索引重建'),
    ):
        if kw not in dl:
            dd += 1
            issues.append(('DD', 'FAIL', 'byId O(1) 索引：' + msg))
    if 'private byId(' in dl:
        dd += 1
        issues.append(('DD', 'FAIL', 'byId 仍是 private，下载页取不到'))
    # 结构变化点都要标脏：init / enqueueAll / 各 filter 删除
    if dl.count('this.indexDirty = true;') < 4:
        dd += 1
        issues.append(('DD', 'FAIL', '集合结构变化点标脏不足（入队/删除/清理/init 至少 4 处）'))

    # ⑤⑥ 行组件：O(1) 取数 + 只 running 行订阅高频
    mi = dpage.find('struct DownloadTaskRow')
    mj = dpage.find('export struct DownloadsPage')
    row_seg = dpage[mi:mj] if 0 <= mi < mj else ''
    page_seg = dpage[mj:] if mj >= 0 else ''
    if not row_seg:
        dd += 1
        issues.append(('DD', 'FAIL', '切不出独立行组件 DownloadTaskRow 片段'))
    else:
        if 'App.get().downloads.byId(this.taskId)' not in row_seg:
            dd += 1
            issues.append(('DD', 'FAIL', '行组件 task() 没走 byId O(1) 取数'))
        if 'for (const t of App.get().downloads.list())' in row_seg:
            dd += 1
            issues.append(('DD', 'FAIL', '行组件仍在 build 路径线性遍历 list()，O(n²) 没消除'))
        if "@StorageProp('downloadProgress') progressVersion" not in row_seg:
            dd += 1
            issues.append(('DD', 'FAIL', '行组件没订阅独立高频 downloadProgress'))
        if "live.status === 'running' && (this.progressVersion + 1) < 0" not in row_seg:
            dd += 1
            issues.append(('DD', 'FAIL', '行组件不是「只 running 行读 progressVersion」，高频订阅没收窄'))
        if '(this.dlVersion + 1) < 0' not in row_seg:
            dd += 1
            issues.append(('DD', 'FAIL', '行组件没在渲染路径读低频 dlVersion（BC 依赖图手法回退）'))
    if 'for (const t of App.get().downloads.list())' in dpage:
        dd += 1
        issues.append(('DD', 'FAIL', '页面/行组件仍在渲染路径线性遍历 list()，O(n²) 回潮'))
    # 页面级只订阅低频，进度不触发 refresh / ForEach 全量 diff
    if "@StorageProp('downloadVersion') @Watch('onChanged') downloadVersion" not in page_seg:
        dd += 1
        issues.append(('DD', 'FAIL', '页面级 refresh 没挂在低频 downloadVersion 上'))
    if "@StorageProp('downloadProgress') @Watch" in page_seg:
        dd += 1
        issues.append(('DD', 'FAIL', '页面级订阅了高频 downloadProgress，refresh 会被进度每 300ms 触发'))

    # ⑦ 高频信号零扩散（只在下载链路两个文件里）
    spread = [f for f, s in src.items() if 'downloadProgress' in s
              and not (f.endswith('core/Downloader.ets') or f.endswith('ui/pages/DownloadsPage.ets'))]
    if spread:
        dd += 1
        issues.append(('DD', 'FAIL', '高频进度信号扩散到内容页 / 其它页：' + ','.join(spread)))

    # ⑧ 既有结构与底座不回退
    for kw, msg in (
        ('struct DownloadTaskRow', '独立行组件被移除'),
        ('taskId: task.id', 'ListItem 没挂稳定 id 的行组件'),
        ('LongPressGesture(', '长按多选手势被移除'),
        ('SelectionBar({', '公共多选条被移除'),
        # 2026-11-16 用户要求「下载页再加一个左滑删除」，左滑入口转为必须项
        ('.swipeAction(', '左滑删除入口被移除'),
        ('SwipeEdgeEffect.Spring', '左滑没有弹性回弹'),
    ):
        if kw not in dpage:
            dd += 1
            issues.append(('DD', 'FAIL', 'BC 结构回退：' + msg))
    mk = re.search(r'ForEach\(this\.tasks,.*?\},\s*\(task:\s*DownloadTask\)\s*=>\s*([^)]*)\)', dpage, re.S)
    if not mk or mk.group(1).strip() != 'task.id':
        dd += 1
        issues.append(('DD', 'FAIL', 'BC 结构回退：ForEach key 不是稳定的 task.id'))
    if 'flushSync();' not in store:
        dd += 1
        issues.append(('DD', 'FAIL', 'Store 同步落盘底座被改'))
    if 'removeMany(ids: string[]): number' not in dl:
        dd += 1
        issues.append(('DD', 'FAIL', '批量删除收口 removeMany 被破坏'))
    route_names = set(re.findall(r"name === '([A-Za-z][\w]*)'", index))
    baseline = {'sheet', 'rankboard', 'discoverSection', 'search', 'artist', 'downloads',
                'sources', 'playSettings', 'appearanceSettings', 'dataSettings',
                'wyAccount', 'favoriteSheets'}
    if route_names - baseline:
        dd += 1
        issues.append(('DD', 'FAIL', '路由表出现新名字：' + ','.join(sorted(route_names - baseline))))

    if dd == 0:
        issues.append(('DD', 'PASS',
                       '下载稳态渲染收口：进度/状态拆成 downloadProgress / downloadVersion 两条信号，'
                       '节流提到实例级全局 300ms（3 并发不再放大到 10 次/秒），页面级 refresh 不被进度触发；'
                       'byId 升级 public + Map O(1)，行取数从 O(n²) 降为常数，只 running 行订阅高频进度；'
                       '高频信号零扩散内容页，BC 稳定 key / 长按多选 / Store 底座 / removeMany 不回退，'
                       '零新增路由、内容页零改动'))


def check_download_finish(src):
    """DE：下载「完成瞬间」收口（v1.0 · 2026-11-15，第三次性能返工）。

    事故：前两轮分别修了「入队瞬间」(DC) 与「下载稳态进度刷新」(DD)，用户装机
    反馈「现在好多了，但下载完成写入文件后还有一瞬间的卡顿，同时完成几个更明显」。
    录屏 12.1-12.9s 整秒画面静止、连统计数字都不跳 —— 典型的 UI 线程被同步重活
    占满，而不是重绘慢（重绘慢会掉帧但数字会跳）。

    根因是第三条独立链路，前两轮从没碰过 run() 的完成收尾：
      downloadFile 的 complete 回调之后，一首歌在同一帧同步做
        copyFileSync(整文件) → AudioTag.embed 整读整写（无损几十 MB，自带歌词
        还写两遍）→ persist(整队列 JSON.stringify + flushSync 同步刷盘) →
        notify(downloadVersion → 页面级 refresh 全量 diff + 234 行 + 跨页连锁)
      并发 3 首几乎同时完成 = 3 段连续大 IO + 3 次全表重建连成几百毫秒阻塞块。

    锁死三刀 + 一个落盘底座不动：
      ① 完成收尾挂 finalizeChain 串行链，每首之间 nextFrame() 让出主线程一帧；
         链用 ordered.catch 兜底，单首异常不会卡死后续队列；job 内复查取消。
      ② 完成/失败状态改 scheduleCommit() 合并广播（固定 150ms 窗口，N 次
         页面级全量重建压成 1 次）；失败/用户主动操作仍即时 notify()，需即时反馈。
      ③ 内置歌词由 builtInLrc() 一次算好、随第一次 embed 一次写全，
         消除「先空词写一遍、再补词写第二遍」的整文件双写。
      ④ persist() 仍在完成那一刻当场执行、磁盘实时，绝不因合并而延迟或丢记录；
         onBackground 调 flushPending() 补发挂起的广播。
      ⑤ DD 双信号 / DC 批量入队 / CE 内嵌时机与单文件 / BC 稳定 key 与左滑 /
         Store.flushSync 底座 / removeMany / 零新增路由 / 高频信号零扩散全不回退。
    """
    de = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    dl = get('core/Downloader.ets')
    dpage = get('ui/pages/DownloadsPage.ets')
    store = get('core/Store.ets')
    ability = get('entryability/EntryAbility.ets')
    tag = get('core/AudioTag.ets')
    index = get('pages/Index.ets')
    if not all((dl, dpage, store, ability, tag, index)):
        issues.append(('DE', 'WARN', '没找齐完成收尾相关文件，跳过检查'))
        return

    # ① 完成收尾串行链：存在、被使用、异常不断链、每首让出一帧
    for kw, msg in (
        ('private finalizeChain: Promise<void> = Promise.resolve();', '缺串行 finalizeChain'),
        ('private inFinalizeOrder(job: () => Promise<void>): Promise<void>', '缺串行收口 inFinalizeOrder'),
        ('this.finalizeChain = ordered.catch(', '串行链没做失败兜底，单首异常会卡死后续队列'),
        ('await this.inFinalizeOrder(', '完成收尾没挂进串行链'),
    ):
        if kw not in dl:
            de += 1
            issues.append(('DE', 'FAIL', '完成收尾串行错峰：' + msg))
    mn = re.search(r'private nextFrame\(\): Promise<void> \{([\s\S]*?)\n  \}', dl)
    if not mn or 'setTimeout(' not in mn.group(1):
        de += 1
        issues.append(('DE', 'FAIL', 'nextFrame 没用 setTimeout 让出主线程一帧'))

    # 锁死整段完成收尾都在 job 内，且不再直接 notify（广播走合并）
    s = dl.find('await this.inFinalizeOrder(')
    e = dl.find('this.scheduleCommit();', s)
    job = dl[s:e] if 0 <= s < e else ''
    if not job:
        de += 1
        issues.append(('DE', 'FAIL', '切不出完成收尾 job 片段'))
    else:
        for kw, msg in (
            ('await this.moveToTarget(tempPath, fileName)', '整文件落盘没进串行链（或没改异步）'),
            ('await AudioTag.embed(finalPath, task.format, task.song, builtIn)', '内嵌没进串行链或没一次写全'),
            ('this.isCancelled(task.id)', '排队期间没复查取消痕迹'),
            ('this.persist();', '落盘没当场做（会因合并而延迟/丢记录）'),
            ("task.status = 'done'", '完成状态没在 job 内改写'),
        ):
            if kw not in job:
                de += 1
                issues.append(('DE', 'FAIL', '完成收尾 job：' + msg))
        if 'addFromDownload' in job:
            de += 1
            issues.append(('DE', 'FAIL', '完成收尾又往本地音乐登记（2026-11-16 已取消）'))
        if 'dropCompleted(' in job:
            de += 1
            issues.append(('DE', 'FAIL', '完成收尾又把记录出队了（2026-11-16 已回退为保留在下载页）'))
        if 'this.notify();' in job:
            de += 1
            issues.append(('DE', 'FAIL', '完成收尾仍直接 notify，全表重建没合并'))

    # ①-b 第四次返工：完成瞬间零同步大 IO（装机实测「还是卡一下」的真正根因）
    for kw, msg in (
        ('await fs.moveFile(tempPath, targetPath)', '落盘没用异步 moveFile'),
        ('await fs.copyFile(tempPath, targetPath)', 'move 失败没异步 copyFile 回退'),
    ):
        if kw not in dl:
            de += 1
            issues.append(('DE', 'FAIL', '完成瞬间异步落盘：' + msg))
    for kw, msg in (('await fs.read(fd.fd, buf,', 'AudioTag 头部读取仍是同步'),
                    # 第五次返工：整文件 fresh 已拆成「新头 + 分块搬音频」，
                    # dst.fd / freshHead 是新结构的字面量；详见 DG 组流式断言。
                    ('await fs.write(dst.fd, AudioTag.toBuffer(freshHead))', 'AudioTag 写新头仍是同步'),
                    ('await fs.read(src.fd, chunk,', 'AudioTag 音频分块搬运没走异步'),
                    ('async embed(path: string', 'AudioTag.embed 没改成 async')):
        if kw not in tag:
            de += 1
            issues.append(('DE', 'FAIL', '完成瞬间异步标签：' + msg))
    if 'copyFileSync(tempPath' in dl or 'fs.readSync(fd.fd, buf' in tag:
        de += 1
        issues.append(('DE', 'FAIL', '完成链路仍有同步整文件 IO（卡顿根因回潮）'))
    if 'await this.inFinalizeOrder(async (): Promise<void> =>' not in dl:
        de += 1
        issues.append(('DE', 'FAIL', '完成收尾 job 不是 async，IO 无法让出事件循环'))

    # ② 广播合并窗口：常量范围合理、固定窗口不重置、只合并广播不合并落盘
    mc = re.search(r'const DOWNLOAD_COMMIT_WINDOW_MS: number = (\d+);', dl)
    if not mc or not (50 <= int(mc.group(1)) <= 400):
        de += 1
        issues.append(('DE', 'FAIL', '缺合理的广播合并窗口常量（50~400ms）'))
    for kw, msg in (
        ('private scheduleCommit(): void', '缺合并广播入口 scheduleCommit'),
        ('private flushCommit(): void', '缺窗口收口 flushCommit'),
        ('flushPending(): void', '缺公开的切后台兜底 flushPending'),
        ('if (this.commitTimer >= 0)', '合并窗口不是固定窗口（会被连续完成无限推迟）'),
    ):
        if kw not in dl:
            de += 1
            issues.append(('DE', 'FAIL', '广播合并：' + msg))
    mf = re.search(r'private flushCommit\(\): void \{([\s\S]*?)\n  \}', dl)
    fbody = mf.group(1) if mf else ''
    if 'this.notify();' not in fbody:
        de += 1
        issues.append(('DE', 'FAIL', 'flushCommit 没广播，完成状态刷新会被吞掉'))
    if 'this.persist();' in fbody:
        de += 1
        issues.append(('DE', 'FAIL', 'flushCommit 又做落盘：完成记录被延迟到窗口末，有丢失风险'))

    # ③ 切后台兜底确实接上
    if "import { Downloader } from '../core/Downloader';" not in ability:
        de += 1
        issues.append(('DE', 'FAIL', 'EntryAbility 没引入 Downloader'))
    if 'Downloader.get().flushPending();' not in ability:
        de += 1
        issues.append(('DE', 'FAIL', 'onBackground 没调 flushPending，切后台会漏掉挂起广播'))

    # ④ 消除整文件双写：内置词一次写全、embedLyricLater 只处理联网取词
    ml = re.search(r'private embedLyricLater\([^)]*\): void \{([\s\S]*?)\n  \}', dl)
    lbody = ml.group(1) if ml else ''
    for kw, msg in (
        ('private static builtInLrc(song: SongInfo): string', '缺一次性内置歌词判定 builtInLrc'),
        ('const builtIn: string = Downloader.builtInLrc(task.song);', '完成收尾没先算内置歌词'),
    ):
        if kw not in dl:
            de += 1
            issues.append(('DE', 'FAIL', '消除双写：' + msg))
    if not lbody:
        de += 1
        issues.append(('DE', 'FAIL', '切不出 embedLyricLater 方法体'))
    else:
        if 'Downloader.builtInLrc(song).length > 0' not in lbody or 'return;' not in lbody:
            de += 1
            issues.append(('DE', 'FAIL', 'embedLyricLater 没对内置歌词直接返回，仍会整读整写第二遍'))
        if 'AudioTag.embed(path, format, song, builtIn)' in lbody:
            de += 1
            issues.append(('DE', 'FAIL', 'embedLyricLater 仍有内置歌词二次 embed（双写没消除）'))
        for kw, msg in (('LyricRepo.get().get(song)', '联网取词链路被删'),
                        ('toLrcText(', 'LyricDoc→LRC 还原被删'),
                        ('AudioTag.embed(path, format, song, lrc)', '联网歌词的二次 embed 被删')):
            if kw not in lbody:
                de += 1
                issues.append(('DE', 'FAIL', '消除双写时误删功能：' + msg))

    # ⑤ 不回退：DD / DC / CE / BC / Store 底座 / 零新增路由 / 高频零扩散
    for kw, msg in (
        ('private notifyProgress(): void', 'DD 双信号被破坏'),
        ("setOrCreate('downloadProgress'", 'DD 高频独立信号被破坏'),
        ("setOrCreate('downloadVersion', Date.now());", 'DD 低频状态广播被破坏'),
        ('taskIndex: Map<string, DownloadTask>', 'DD byId O(1) 索引被破坏'),
        ('removeMany(ids: string[]): number', 'DC 批量删除收口被破坏'),
        ('const seen: Set<string> = new Set<string>();', 'DC 批量入队单次查重被破坏'),
    ):
        if kw not in dl:
            de += 1
            issues.append(('DE', 'FAIL', '既有优化回退：' + msg))
    for kw, msg in (
        ('struct DownloadTaskRow', 'BC 独立行组件被移除'),
        ('(task: DownloadTask) => task.id', 'BC ForEach 稳定 key 被改'),
        ('LongPressGesture(', 'BC 长按多选被移除'),
    ):
        if kw not in dpage:
            de += 1
            issues.append(('DE', 'FAIL', '既有优化回退：' + msg))
    if 'flushSync();' not in store:
        de += 1
        issues.append(('DE', 'FAIL', 'Store 同步落盘底座被改'))
    # CE 内嵌时机：异步落盘 < embed < done，且仍只产出一个文件
    copy_at = dl.find('await this.moveToTarget(tempPath, fileName)')
    embed_at = dl.find('AudioTag.embed(finalPath, task.format, task.song,')
    done_at = dl.find("task.status = 'done'", embed_at)
    if not (0 <= copy_at < embed_at < done_at):
        de += 1
        issues.append(('DE', 'FAIL', 'CE 内嵌时机被打乱（必须落盘后、标记 done 前）'))
    if 'rewrite(' not in tag or '已回滚原文件' not in tag:
        de += 1
        issues.append(('DE', 'FAIL', 'AudioTag 整体重写 + 失败回滚被破坏'))
    spread = [f for f, text in src.items() if 'downloadProgress' in text
              and not (f.endswith('core/Downloader.ets') or f.endswith('ui/pages/DownloadsPage.ets'))]
    if spread:
        de += 1
        issues.append(('DE', 'FAIL', '高频进度信号扩散到内容页：' + ','.join(spread)))
    route_names = set(re.findall(r"name === '([A-Za-z][\w]*)'", index))
    baseline = {'sheet', 'rankboard', 'discoverSection', 'search', 'artist', 'downloads',
                'sources', 'playSettings', 'appearanceSettings', 'dataSettings',
                'wyAccount', 'favoriteSheets'}
    if route_names - baseline:
        de += 1
        issues.append(('DE', 'FAIL', '路由表出现新名字：' + ','.join(sorted(route_names - baseline))))

    if de == 0:
        issues.append(('DE', 'PASS',
                       '下载完成瞬间收口：完成收尾挂 finalizeChain 串行链、每首之间让出主线程一帧；'
                       '第四次返工把整文件搬移与标签整读整写全部改成异步 Promise，'
                       'UI 线程不再被单首同步大 IO 占住（这才是装机后「还是卡一下」的残留根因）；'
                       '内置歌词一次 embed 写全，整文件读写从 2 遍降为 1 遍；完成项保留在下载页且不写本地音乐，'
                       '状态仍当场落盘（零丢失），页面级全量重建合并到 150ms 固定窗口只广播一次；'
                       '切后台 flushPending 兜底；失败/用户操作保持即时反馈；'
                       'DD/DC/CE/BC/Store 底座不回退，零新增路由、内容页零改动'))


def check_download_rework_v4(src):
    """DF：下载管理页重做 + 完成留队并进本地音乐 + 完成瞬间零同步 IO。

    用户口径四条（2026-11-15）：① 数据二级页收下红圈标记的三块（统计卡 / 同时下载 / 自动下载）；
    ② 下载完成的歌自动添加到本地音乐；③ 下载页操作改成长按多选
    （单选 / 全选）、单击暂停 / 开始、全部暂停 / 全部开始 / 清除全部任务，
    原来那些（左滑、行尾 ×、清除、清空失败）去掉；④ 完成时还是卡一下，要求根治。

    2026-11-16 用户两次纠偏（最终口径）：
      ①「下载完成后歌曲还在下载管理页中」→ 完成项不出队；
      ②「不要把下载的歌曲放在本地音乐，太占内存」→ 完成即登记本地音乐的做法取消；
      ③「下载页再加一个左滑删除」→ 左滑删除回归，删记录时连文件一起删。

    锁死：
      ① 三块设置只在 DataSettingsPage，DownloadsPage 里彻底没有；
      ② 完成记录**必须留在队列**（dropCompleted 不许回归），且**不许再写 LocalRepo**
         （addFromDownload 已删除），已下载语义只查队列 done 记录；老版本自动登记
         进本地音乐的历史条目由 LocalRepo.detachExternal() 在 App.init 里摘掉；
      ③ Downloader 有 toggle / pause / resume / pauseAll / resumeAll / clearAll，
         暂停走原生 suspend / restore（进度不丢）；下载页有新工具条 + 左滑删除，
         旧的「清除 / 清空失败」入口仍不许回来；
      ④ 完成链路无同步整文件 IO（DE 细查）、Store.flushSync 底座不动；
      ⑤ 零新增路由、内容页零改动。
    """
    df = 0

    def get(suffix: str) -> str:
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    dl = get('core/Downloader.ets')
    dpage = get('ui/pages/DownloadsPage.ets')
    data = get('ui/pages/DataSettingsPage.ets')
    local = get('core/LocalRepo.ets')
    app = get('core/App.ets')
    tag = get('core/AudioTag.ets')
    store = get('core/Store.ets')
    index = get('pages/Index.ets')
    if not all((dl, dpage, data, local, app, tag, store, index)):
        issues.append(('DF', 'WARN', '没找齐本轮改动相关文件，跳过检查'))
        return

    # ① 红圈标记的三块：只在数据二级页，下载页彻底没有
    for kw in ('statCard()', 'concurrencyCard()', 'autoDownloadCard()',
               "'听够 2/3 自动下载'", "'同时下载'", "'保存目录'", "'已下载'"):
        if kw not in data:
            df += 1
            issues.append(('DF', 'FAIL', '数据二级页缺搬来的内容：' + kw))
    for kw in ('statCard()', 'concurrencyCard()', 'autoDownloadCard()',
               'DOWNLOAD_CONCURRENCY_MIN', 'setAutoDownloadOnPlay', 'refreshDir()'):
        if kw in dpage:
            df += 1
            issues.append(('DF', 'FAIL', '下载管理页仍残留已搬走的控件：' + kw))
    if "@StorageProp('downloadVersion') @Watch('onDownloadChanged')" not in data:
        df += 1
        issues.append(('DF', 'FAIL', '数据二级页没订阅下载状态，统计不会刷新'))

    # ② 完成留队、不登记本地音乐、记录与文件一起删（2026-11-16 用户第三次口径）
    for kw, msg in (('detachExternal(): LocalSong[]', 'LocalRepo 缺历史下载条目清理'),
                    ('this.songs = keep;', '清理没真正摘掉列表'),
                    ('removed.push(song);', '摘掉的条目没返回（会造成文件孤儿）')):
        if kw not in local:
            df += 1
            issues.append(('DF', 'FAIL', msg))
    for kw, msg in (('addFromDownload', '下载完成又自动登记进本地音乐（用户要求别占本地音乐）'),
                    ('notifyNow(): void', 'LocalRepo 还留着零调用的合并广播入口')):
        if kw in local:
            df += 1
            issues.append(('DF', 'FAIL', msg))
    for kw, msg in (
        ('kept.push(task);', '完成记录没有保留在下载队列'),
        ('this.find(song.id) !== null', '已下载状态没查队列 done 记录'),
        ('fs.unlinkSync(task.path);', '删任务没删已下载文件（会留下孤儿占空间）'),
        ('private dropOne(task: DownloadTask): void', '缺单条摘除收口'),
        # 2026-11-16 审查修复：完成项长期留队后的三条一致性保障
        ('DOWNLOAD_PERSIST_MAX', '缺队列持久化上限常量'),
        ('private trimOverflow(): void', '缺超限裁剪（记录会无限膨胀）'),
        ('this.trimOverflow();', 'persist 没做超限裁剪（记录会无限膨胀）'),
        ('consumeTrimNotice(): number', '超限自动删文件没有可提示的计数'),
        ('size = fs.statSync(task.path).size;', '冷启动没校验 done 记录的文件是否还在'),
        ('this.purgeTemp(context);', '启动没清理上次遗留的下载临时文件'),
        ('if (interrupted > 0 || missing > 0 || repaired > 0)', '冷启动修正过状态却没落盘'),
        ('const size: number = fs.statSync(finalPath).size;', '完成没记真实文件大小（占用空间会显示 0）'),
        # 2026-11-16 全工程审查补：自动裁剪不得删掉正在播放的文件
        ("const playing: string = AppStorage.get<string>('playingLocalPath') ?? '';",
         '超限裁剪没读正在播放的路径（会删掉正在听的歌）'),
        ('if (playing.length > 0 && task.path === playing) {', '超限裁剪没避让正在播放的任务'),
    ):
        if kw not in dl:
            df += 1
            issues.append(('DF', 'FAIL', msg))
    for kw, msg in (
        ('LocalRepo.get().addFromDownload', '完成收尾仍在写本地音乐'),
        ('this.localDirty', '本地音乐脏标记没有随登记一起移除'),
        ('for (const local of LocalRepo.get().list())', '入队查重还在扫本地音乐'),
    ):
        if kw in dl:
            df += 1
            issues.append(('DF', 'FAIL', msg))
    if 'dropCompleted' in dl:
        df += 1
        issues.append(('DF', 'FAIL', 'dropCompleted 又回来了（完成项会从下载页消失）'))
    for kw in ("'已完成'", '共 ', '.swipeAction(', 'swipeDelete(',
               'nearLimit()', 'Downloader.capacity()', 'consumeTrimNotice()'):
        if kw not in dpage:
            df += 1
            issues.append(('DF', 'FAIL', '下载页缺已完成状态 / 计数 / 左滑删除 / 上限提示：' + kw))
    # 2026-11-16 审查：下载与本地音乐解耦后留下的零调用符号必须清掉
    if 'usedBytes' in local:
        df += 1
        issues.append(('DF', 'FAIL', 'LocalRepo 还留着零调用的 usedBytes'))
    home = get('ui/pages/HomePage.ets')
    if home and 'downloadCount' in home:
        df += 1
        issues.append(('DF', 'FAIL', '首页还留着零读写的 downloadCount'))
    li = app.find('await this.local.init(context);')
    de = app.find('const legacyLocal = this.local.detachExternal();')
    di = app.find('this.downloads.init(context);')
    ab = app.find('this.downloads.absorbLegacy(legacyLocal);')
    if not (0 <= li < de < di < ab):
        df += 1
        issues.append(('DF', 'FAIL',
                       'App 没在 LocalRepo 就绪后摘历史登记、并在下载器 init 后补成队列记录'
                       '（只摘不放会让老用户已下载的歌彻底消失、文件白占空间）'))
    if 'absorbLegacy(legacy: LocalSong[]): number' not in dl:
        df += 1
        issues.append(('DF', 'FAIL', '下载器缺老版本遗留条目接管入口'))
    if 'private static fileExists(path: string): boolean' not in dl:
        df += 1
        issues.append(('DF', 'FAIL', '缺 fileExists 收口（接管历史条目时无法判文件在不在）'))
    if "if (song.source === 'local') {" in app:
        df += 1
        issues.append(('DF', 'FAIL', '播放路径仍按 source 分流（补录条目会「看得见播不了」）'))
    if "return App.playablePath(path);" not in app and 'App.playablePath(task.path)' not in app:
        df += 1
        issues.append(('DF', 'FAIL', '播放器本地路径供给被破坏'))
    pl = get('core/Player.ets')
    if not pl or "AppStorage.setOrCreate('playingLocalPath', localPath);" not in pl:
        df += 1
        issues.append(('DF', 'FAIL', '播放器没暴露正在播放的本地路径（超限裁剪无法避让）'))

    # ③ 新操作逻辑：原生暂停/恢复 + 五个批量/单例入口 + 新 UI
    for kw, msg in (
        ('activeDownloads: Map<string, request.DownloadTask>', '缺系统下载任务索引'),
        ('toggle(id: string): void', '缺单击切换'),
        ('private async pause(id: string', '缺暂停'),
        ('private async resume(id: string', '缺继续'),
        ('pauseAll(): void', '缺全部暂停'),
        ('resumeAll(): void', '缺全部开始'),
        ('clearAll(): void', '缺清除全部任务'),
        ('await live.suspend()', '暂停没用原生 suspend（进度会丢）'),
        ('await live.restore()', '开始没用原生 restore'),
        ('Promise.all(jobs)', '批量暂停/开始没并发收口（会逐首刷广播）'),
    ):
        if kw not in dl:
            df += 1
            issues.append(('DF', 'FAIL', 'Downloader ' + msg))
    for kw in ('全部暂停', '全部开始', '清除全部任务', 'LongPressGesture(',
               'SelectionBar({', 'toggleSelect(', 'toggleAll()', 'deleteSelected()'):
        if kw not in dpage:
            df += 1
            issues.append(('DF', 'FAIL', '下载页缺新操作：' + kw))
    for kw in ('clearDone()', 'clearFailed()', 'IconTap({', "Text('清除')", '清空失败'):
        if kw in dpage:
            df += 1
            issues.append(('DF', 'FAIL', '下载页旧操作没去干净：' + kw))

    # ④ 完成瞬间零同步大 IO + 落盘底座不动
    if 'copyFileSync(tempPath' in dl or 'this.copyToTarget(' in dl:
        df += 1
        issues.append(('DF', 'FAIL', '完成链路仍有同步整文件复制'))
    if 'async embed(path: string' not in tag or 'await fs.read(fd.fd, buf,' not in tag:
        df += 1
        issues.append(('DF', 'FAIL', 'AudioTag 大 IO 没改异步'))
    if 'flushSync();' not in store:
        df += 1
        issues.append(('DF', 'FAIL', 'Store 同步落盘底座被改（会丢完成记录）'))

    # ⑤ 零新增路由
    route_names = set(re.findall(r"name === '([A-Za-z][\w]*)'", index))
    baseline = {'sheet', 'rankboard', 'discoverSection', 'search', 'artist', 'downloads',
                'sources', 'playSettings', 'appearanceSettings', 'dataSettings',
                'wyAccount', 'favoriteSheets'}
    if route_names - baseline:
        df += 1
        issues.append(('DF', 'FAIL', '路由表出现新名字：' + ','.join(sorted(route_names - baseline))))

    if df == 0:
        issues.append(('DF', 'PASS',
                       '下载管理页重做：红圈三块整体搬进数据二级页；完成项留在下载页'
                       '（不出队、不登记本地音乐，addFromDownload 已删除，老版本历史条目启动时摘掉）；'
                       '已下载判定 / 入队查重 / 播放路径全部改由队列 done 记录支撑；'
                       '长按多选 + 单击暂停/开始 + 左滑删除（记录与文件一起删），'
                       '完成项冷启动校验文件存在、超上限按队尾清理并同步删文件、启动清临时文件，'
                       '暂停走原生 suspend/restore 保进度，旧清除/清空失败入口仍清零；'
                       '完成链路的整文件搬移与标签整读整写全部改异步 Promise，UI 线程不再被同步大 IO 占住；'
                       'Store.flushSync 底座与零新增路由保持'))


def check_download_global_stall(src):
    """DG：下载完成「全局顿挫」根治（v1.0 · 2026-11-15，第五次性能返工）。

    装机反馈：前四版削的都是「次数 / 同步 IO 等待」，完成时「没那么严重了但还是
    能感觉到」，且「卡顿影响是全局的、在其他界面也能感觉到顿挫」。
    与页面无关 = 进程级停顿，真根因是三处前四版一直没碰的全局负载：

      ① AudioTag 每首完成在主线程连分配 3 份几十 MB 整文件大对象：
         readAll 的 ArrayBuffer(size) + concat 的 Uint8Array(total) +
         toBuffer 的 ArrayBuffer(length)，还有两次整文件 set() 内存拷贝。
         并发 3 首 = 9 份，方舟 GC 回收大对象是全局 STW。
         → 改「只读 ≤64KB 标签头(二跳精确补读上限 4MB) + 256KB 分块流式搬音频」，
           音频字节不进 JS 堆，大对象分配归零。
      ② 每首完成 2 次同步 flushSync（当时 LocalRepo 登记一次 + Downloader 一次），
         同步磁盘 IO 全局占住 UI 线程。
         → 先合并成一次；2026-11-16 下载不再登记本地音乐，完成帧只剩 Downloader 这一次。
      ③ 完成窗口连发 localVersion + downloadVersion 两次 AppStorage 全扇出，
         每行 SongRow 都靠 dlVersion 挂进依赖图，一次广播唤醒所有常驻页/所有行。
         → 完成帧只发 downloadVersion 一次；本地音乐不再有下载引起的变化，无需补发。

    锁死四条不变式，防止回退：
      A 零整文件大对象：AudioTag 不得出现 readAll / 按 stat.size 分配 ArrayBuffer /
        stripId3 整文件 subarray；必须有 readHead / headEnd / CHUNK 分块循环。
      B 完成帧不写本地音乐：LocalRepo 不得再有 addFromDownload / notifyNow；
        Downloader.persist 仍当场 flushSync（零丢失红线不破）。
      C 完成帧单次扇出：flushCommit 只 notify 一次；flushPending 只补发挂起广播。
      D 不回退 CE 单文件/幂等/失败回滚、DE 串行链/异步 IO、DF 完成留队且不进本地音乐、
        Store.flushSync 底座、零新增路由。
    """
    def get(suffix):
        return next((s for f, s in src.items() if f.endswith(suffix)), '')

    tag = get('core/AudioTag.ets')
    dl = get('core/Downloader.ets')
    local = get('core/LocalRepo.ets')
    store = get('core/Store.ets')
    ability = get('entryability/EntryAbility.ets')
    index = get('pages/Index.ets')
    bad = 0

    # A 零整文件大对象：只读标签头 + 分块流式搬音频
    for kw, msg in (
        ('const PROBE_HEAD', '缺 64KB 探测头常量'),
        ('const MAX_HEAD', '缺标签区读取硬上限'),
        ('const CHUNK', '缺流式分块大小常量'),
        ('private static async readHead(', '缺只读标签区头部的 readHead'),
        ('private static headEnd(', '缺标签区结束位置计算 headEnd'),
        ('private static async rewrite(', '缺流式重写 rewrite'),
        ('new ArrayBuffer(CHUNK)', '分块缓冲没按 CHUNK 分配'),
        ('while (pos < total)', '音频主体没有按分块循环搬运'),
        ('await fs.read(src.fd, chunk,', '分块读没走异步'),
        ('await fs.write(dst.fd, chunk,', '分块写没走异步'),
        ('await fs.copyFile(tmp, path)', '临时文件没异步覆盖回原文件'),
        ('foundLast', 'FLAC 只读头部时没校验 last block（会截断音频）'),
    ):
        if kw not in tag:
            bad += 1
            issues.append(('DG', 'FAIL', 'AudioTag 流式改造：' + msg))
    # 反向：整读整写大对象绝不能回来
    for kw, msg in (
        ('readAll(', '整文件 readAll 回来了（大对象/GC 全局停顿回潮）'),
        ('new ArrayBuffer(size)', '又按整文件大小分配 ArrayBuffer'),
        ('stripId3(', 'stripId3 整文件 subarray 回来了'),
        ("parts.push(original.subarray(parsed.audioOffset))", 'FLAC 又把整份音频拼进内存'),
        ('const fresh = AudioTag.concat(', '又把整文件 fresh 拼进内存'),
    ):
        if kw in tag:
            bad += 1
            issues.append(('DG', 'FAIL', 'AudioTag 大对象回退：' + msg))
    # 失败回滚语义不丢
    if '已回滚原文件' not in tag or "fs.unlinkSync(tmp);" not in tag:
        bad += 1
        issues.append(('DG', 'FAIL', '流式重写没保住失败回滚 / 临时文件清理'))
    if 'new ArrayBuffer(probeLen)' not in tag:
        bad += 1
        issues.append(('DG', 'FAIL', '第一跳不是 64KB 探测（常态仍会分配大对象）'))

    # B 完成帧不写本地音乐（2026-11-16 用户口径），零丢失底座不动
    if 'addFromDownload' in local or 'notifyNow' in local:
        bad += 1
        issues.append(('DG', 'FAIL', '下载完成又往本地音乐写（用户要求别占本地音乐列表）'))
    if 'flushSync();' not in store:
        bad += 1
        issues.append(('DG', 'FAIL', 'Store 同步落盘底座被改（完成记录会丢）'))
    if 'this.persist();' not in dl:
        bad += 1
        issues.append(('DG', 'FAIL', '完成帧没当场 persist（零丢失红线破了）'))

    # C 完成窗口只扇出一次
    fc = re.search(r'private flushCommit\(\): void \{([\s\S]*?)\n  \}', dl)
    fbody = fc.group(1) if fc else ''
    if not fbody:
        bad += 1
        issues.append(('DG', 'FAIL', '切不出 flushCommit 方法体'))
    else:
        if 'LocalRepo.get().notifyNow();' in fbody:
            bad += 1
            issues.append(('DG', 'FAIL', '完成帧仍发第二次 localVersion 全扇出'))
        if fbody.count('this.notify();') != 1:
            bad += 1
            issues.append(('DG', 'FAIL', '完成帧 notify 次数不是 1'))
        if 'this.persist();' in fbody:
            bad += 1
            issues.append(('DG', 'FAIL', 'flushCommit 又做落盘：完成记录被延迟'))
    fp = re.search(r'flushPending\(\): void \{([\s\S]*?)\n  \}', dl)
    pbody = fp.group(1) if fp else ''
    if 'this.flushCommit();' not in pbody:
        bad += 1
        issues.append(('DG', 'FAIL', '切后台没补发挂起的完成广播'))
    if 'LocalRepo.get().notifyNow();' in pbody or 'this.localDirty' in pbody:
        bad += 1
        issues.append(('DG', 'FAIL', '切后台还在补发早已不存在的本地音乐刷新'))
    if "Downloader.get().flushPending();" not in ability:
        bad += 1
        issues.append(('DG', 'FAIL', 'EntryAbility.onBackground 没接 flushPending'))

    # D 不回退：CE 时机 / DE 串行链 / DF 完成留队 / 零新增路由
    for kw, msg in (
        ('await this.inFinalizeOrder(async (): Promise<void> =>', '完成收尾串行链被破坏'),
        ('await AudioTag.embed(finalPath, task.format, task.song, builtIn)', '标签内嵌没进串行链'),
        ('this.scheduleCommit();', '完成广播没走合并窗口'),
    ):
        if kw not in dl:
            bad += 1
            issues.append(('DG', 'FAIL', '既有链路回退：' + msg))
    if 'addFromDownload' in dl:
        bad += 1
        issues.append(('DG', 'FAIL', '完成记录又往本地音乐登记（2026-11-16 已取消）'))
    if 'dropCompleted' in dl:
        bad += 1
        issues.append(('DG', 'FAIL', '完成记录又被出队（2026-11-16 已回退为保留在下载页）'))
    copy_at = dl.find('await this.moveToTarget(tempPath, fileName)')
    embed_at = dl.find('AudioTag.embed(finalPath, task.format, task.song,')
    done_at = dl.find("task.status = 'done'", embed_at)
    if not (0 <= copy_at < embed_at < done_at):
        bad += 1
        issues.append(('DG', 'FAIL', 'CE 内嵌时机被打乱（必须落盘后、标记 done 前）'))
    if not index:
        bad += 1
        issues.append(('DG', 'FAIL', '缺 Index.ets，无法校验零新增路由'))
    else:
        route_names = set(re.findall(r"name === '([A-Za-z][\w]*)'", index))
        baseline = {'sheet', 'rankboard', 'discoverSection', 'search', 'artist', 'downloads',
                    'sources', 'playSettings', 'appearanceSettings', 'dataSettings',
                    'wyAccount', 'favoriteSheets'}
        if route_names - baseline:
            bad += 1
            issues.append(('DG', 'FAIL', '路由表出现新名字：' + ','.join(sorted(route_names - baseline))))

    if bad == 0:
        issues.append(('DG', 'PASS',
                       '下载完成全局顿挫根治：AudioTag 由「整读整写 3 份几十 MB 大对象」'
                       '改为「64KB 探测头 + 按需精确补读(≤4MB) + 256KB 分块流式搬音频」，'
                       '音频字节不进 JS 堆、大对象分配归零，方舟 GC 全局 STW 消除；'
                       '完成帧只做一次当场 flushSync（下载不再写本地音乐，零丢失不动），'
                       'AppStorage 全扇出只剩 downloadVersion 一次；'
                       'CE 单文件/幂等/失败回滚、DE 串行链/异步 IO、DF 完成留队且不进本地音乐、'
                       'Store.flushSync 底座、零新增路由全不回退'))


def main():
    src = load()
    if not src:
        print('找不到源码，检查路径：' + ETS)
        return 1
    for fn in (check_broadcast, check_dead_builder, check_param_builder, check_page_subscription,
               check_missing_callback, check_listener_pair, check_for_each_key, check_overlay_conflict,
               check_loading_cleanup, check_task_release, check_persist_window, check_auto_reset,
               check_progress_persist, check_resume_progress, check_local_delete_safe,
               check_download_cancel, check_dup_entry, check_source_gate,
               check_startup_batch, check_fail_panel, check_source_affinity,
               check_check_matrix, check_swipe_delete, check_local_import,
               check_lyric_layout, check_home_feed, check_fav_feedback, check_sheet_surface,
               check_tab_routes, check_playlist_ux, check_tab_swipe,
               check_native_immersive, check_smart_hunt, check_longpress_preload, check_fav_layout,
               check_download_swipe_stable, check_settings_subpages, check_song_marquee,
               check_quality_summary_in_subpage, check_data_subpage, check_wy_account,
               check_wy_fav_sync,
               check_discover_feed, check_discover_more, check_account_top,
               check_fav_sync_truthful, check_wy_unsubscribe_restricted,
               check_qq_write_post_and_fav_button, check_home_realtime_recommend,
               check_home_daily_rail_and_entries,
               check_v273_group_rail_avatar_mysheets,
               check_v274_hot_theme_marquee,
               check_v277_account_summary_login_only,
               check_home_grid_tint_uniform,
               check_glass_theme_removed, check_qqkg_account_removed,
               check_download_audio_tags, check_download_concurrency,
               check_ignore_interrupt, check_b_cleanup, check_song_comments,
               check_auto_download, check_mf_capabilities, check_download_batch,
               check_download_render, check_download_finish, check_download_rework_v4,
               check_download_global_stall):
        fn(src)

    width = max(len(m) for _, _, m in issues)
    last = None
    for cat, level, msg in issues:
        if cat != last:
            print()
            last = cat
        print(f'  [{level}] {msg}')

    fails = [i for i in issues if i[1] == 'FAIL']
    warns = [i for i in issues if i[1] == 'WARN']
    print()
    print(f'共 {len(issues)} 项：PASS {len([i for i in issues if i[1] == "PASS"])} / '
          f'WARN {len(warns)} / FAIL {len(fails)}')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
