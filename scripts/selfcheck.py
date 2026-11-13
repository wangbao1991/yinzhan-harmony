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
          'markGlyph'}


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

    labels = re.findall(r"label:\s*'([^']+)'", shell)
    if labels != ['首页', '发现', '设置']:
        bad += 1
        issues.append(('AC', 'FAIL',
                       '底栏不是「首页 / 发现 / 设置」：音乐库已并入首页，发现必须占第二个位置'))

    tabs = _func_body(index, 'tabContent')
    if 'HomePage(' not in tabs:
        bad += 1
        issues.append(('AC', 'FAIL', '首页没挂进一级页容器，点底栏「首页」会是空白'))
    if 'DiscoverPage()' not in tabs:
        bad += 1
        issues.append(('AC', 'FAIL', '发现页没挂进一级页容器，点底栏「发现」会是空白'))
    if 'SettingsPage()' not in tabs:
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
    stats = next((s for f, s in src.items() if f.endswith('core/PlayStats.ets')), '')
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
    if 'reload(): void' not in library or 'reload(): void' not in stats:
        bad += 1
        issues.append(('AC', 'FAIL', 'Library / PlayStats 缺 reload()：恢复后界面仍显示旧内存数据'))
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
        ('PlayStats', stats, r'playsInDays|msTotal|finishedTotal|lastDayMap|自动歌单读取'),
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
    if '不是歌手全部专辑总数' not in artist_page:
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
    if '自建歌单' in data_view:
        bad += 1
        issues.append(('AC', 'FAIL', '数据说明仍写「自建歌单」：工程没有新建歌单入口'))
    if '音源脚本（含脚本正文' not in data_view:
        bad += 1
        issues.append(('AC', 'FAIL', '数据管理页数据说明没把音源脚本列入备份范围'))

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
    if "reason + '；脚本已就绪，仍会被搜索问到" not in src_page:
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
        ('const reason = item.message.length > 0', '自检失败没读取真实结论 message'),
        ('脚本已就绪，仍会被搜索问到，可点「自检」重试', '自检失败没说明「源还在搜索里」'),
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
    # ④ 下载页：入口早已移除，多选状态机与批量删除已无触发路径，残留即死代码
    dl_page = next((s for f, s in src.items() if f.endswith('ui/pages/DownloadsPage.ets')), '')
    for kw in ('selectMode', 'selectedIds', 'toggleSelectAll', 'confirmDeleteSelected', 'removeMany'):
        if kw in dl_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.55 下载页仍有不可达的多选残留：' + kw))

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
    # ④ 设置页迁移提示条 + 旧 key 只读
    # v2.62：光感迁移提示随「主题」搬进外观二级页，守断言的读取范围跟着扩到
    # 「设置主页 + 外观页」，六条约束一条不删（只是允许它出现在二级页里）。
    st_page = next((s for f, s in src.items() if f.endswith('ui/pages/SettingsPage.ets')), '') + \
        next((s for f, s in src.items() if f.endswith('ui/pages/AppearanceSettingsPage.ets')), '')
    art_page = next((s for f, s in src.items() if f.endswith('ui/pages/ArtistPage.ets')), '')
    ab_src = next((s for f, s in src.items() if f.endswith('entryability/EntryAbility.ets')), '')
    const_src = next((s for f, s in src.items() if f.endswith('common/Constants.ets')), '')
    settings_core = next((s for f, s in src.items() if f.endswith('core/Settings.ets')), '')
    if "LIGHT_SENSE_NOTICE: string = 'v4_light_sense_notice'" not in const_src:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 没有「光感提示已看过」的独立 key（不能覆盖旧档位值）'))
    if 'lightSenseNoticeSeen(): boolean' not in settings_core or \
            'setLightSenseNoticeSeen(): void' not in settings_core:
        bad += 1
        issues.append(('AC', 'FAIL', 'v2.56 Settings 没有提示标记的读写'))
    for kw, msg in (
        ('@State lightNotice: boolean = false;', '没有一次性提示状态'),
        ('private needLightNotice(): boolean', '提示条件没抽成可执行的方法'),
        ('this.settings.lightSense() !== 3', '没判断「曾选过非默认档」，会骚扰从没动过的用户'),
        ("Text('知道了')", '提示条没有关闭动作'),
        ('this.settings.setLightSenseNoticeSeen()', '关掉提示后没落盘，下次还会出现'),
        ('光感四档已取消', '提示文案丢失'),
    ):
        if kw not in st_page:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.56 SettingsPage ' + msg))
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
        ('@State idleTipOpen: boolean = false;', 'idle 页长说明又整块摊开'),
        ("'五大平台和已启用的插件都没搜到", '空态文案退回旧措辞，三段式没落地'),
    ):
        if kw not in search_src:
            bad += 1
            issues.append(('AC', 'FAIL', 'v2.54 包 2：' + msg))

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
    """AE：一级页横滑切页 + 底栏两种形态。

    用户拿参考软件要「底部 tab 栏的滑动、自动缩放、自动伸展」，实测是两件事：
      1. 横滑切页：容器必须是能跟手的 Swiper。原来是 Stack + visibility，
         手指横滑毫无反应，底栏也没有「选中块滑过去」的参照物；
      2. 收起形态：参考软件不是把整条栏缩窄（那只是变小，还是同一条栏），
         而是换成一排——左边一枚当前页的圆形按钮，右边一条迷你播放胶囊，
         横向铺满。所以「播放条」必须在收起时并进这一行，
         而不是继续挂在底栏上方单独一条（那样看着就是「缩水」）。
    另外 loop 必须关掉：末页再右滑绕回首页时，底栏指示器会从 2/3 位置瞬移回 0，
    用户会以为点错了页。
    """
    index = next((s for f, s in src.items() if f.endswith('pages/Index.ets')), '')
    shell = next((s for f, s in src.items() if f.endswith('ui/Shell.ets')), '')
    if not index or not shell:
        issues.append(('AE', 'WARN', '缺文件，跳过横滑切页检查'))
        return
    bad = 0

    tabs = _func_body(index, 'tabContent') or ''
    if not re.search(r'\bSwiper\(', tabs):
        bad += 1
        issues.append(('AE', 'FAIL', '一级页容器不是 Swiper：横滑切不动，底栏指示器也没有跟手来源'))
    if 'visibility(this.tab' in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', '还在用 visibility 切页：这种写法只支持点底栏，横滑无效'))
    # 指示器位置有两条合法路线：
    #   a) 拖动中跟手 —— 必须接满 4 个参数。少接第一个会整体错位：
    #      position 位拿到整数索引，at 直接 +1，手指刚碰屏幕指示器就跳到最后一格。
    #   b) 只跟当前页 —— onChange 广播 tabSwipe，指示器自己补间过去。
    # 两条都不占，就是换页硬跳。
    if '.onContentDidScroll(' in tabs:
        m = re.search(r'\.onContentDidScroll\(\s*\(([^)]*)\)', tabs)
        n = len([x for x in m.group(1).split(',') if x.strip()]) if m else 0
        if n < 4:
            bad += 1
            issues.append(('AE', 'FAIL',
                           f'onContentDidScroll 只接了 {n} 个参数：SDK 是 4 个，少接会整体错位、指示器一碰就跳页'))
    if '.onGestureSwipe(' not in tabs and '.onContentDidScroll(' not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', '没有跟手回调：拖动时指示器完全不动'))

    # 跟手必须走 onGestureSwipe 的 currentOffset（vp，带符号、语义明确）。
    # 不要再用 onContentDidScroll 的 position —— 真机上它给出的值对不上文档，
    # 手指刚动就指到最后一格。
    if '.onGestureSwipe(' in tabs and 'currentOffset' not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', '跟手回调没读 currentOffset：拿不到带符号的位移，算不出真实位置'))
    if '.onContentDidScroll(' in tabs and '.onGestureSwipe(' in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', '两套跟手回调同时存在：两处都在写 tabSwipe，位置会打架'))
    if "'tabSwipe'" not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', '横滑进度没广播 tabSwipe，指示器拿不到连续位置'))
    if '.loop(false)' not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', 'Swiper 开了 loop：末页再右滑会绕回首页，底栏顺序对不上'))
    if '.index(this.tab)' not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', 'Swiper 没绑 index(this.tab)：点底栏切页容器不会动'))

    switch = _func_body(index, 'switchTab') or ''
    if 'changeIndex(' not in switch:
        bad += 1
        issues.append(('AE', 'FAIL', '点底栏没走 changeIndex：页面直接跳过去，没有过场'))

    # 指示器：整条栏里唯一横向移动的元素，宽度等分、位置 = 索引 + 拖动比例
    # 用方法定义精确匹配：只查 'pillX(' 的话，调用点还能命中，改名骗得过去
    if not re.search(r'private\s+pillX\s*\(', shell) or not re.search(r'private\s+pillWidth\s*\(', shell):
        bad += 1
        issues.append(('AE', 'FAIL', '底栏没有滑动指示器（pillX / pillWidth）：选中态只是换颜色，看不出「滑动」'))
    if "'tabSwipe'" not in shell:
        bad += 1
        issues.append(('AE', 'FAIL', '底栏没订阅 tabSwipe，指示器不会跟着横滑走'))

    # 收起形态：参考软件是「圆按钮 + 播放胶囊」重新排一行，不是把整条缩窄。
    # 只缩窄的话横向留一大截空，用户一眼就看出「只是变小了」。
    if not re.search(r'private\s+collapse\s*\(', shell):
        bad += 1
        issues.append(('AE', 'FAIL', '底栏没有收起系数 collapse()：展开/收起两态没有统一的驱动值'))
    if not re.search(r'MiniPlayer\(\{\s*inline:\s*true\s*\}\)', shell):
        bad += 1
        issues.append(('AE', 'FAIL', '收起态没把迷你播放条并进来（MiniPlayer inline）：播放条还单独挂在上面一条'))
    if not re.search(r"SymbolGlyph\(\$r\('sys\.symbol\.house_fill'\)\)", shell):
        bad += 1
        issues.append(('AE', 'FAIL', '收起态缺圆形首页按钮：收起后没有回首页/展开底栏的入口'))
    if re.search(r'private\s+barWidth\s*\(', shell):
        bad += 1
        issues.append(('AE', 'FAIL', '底栏还在整条缩窄（barWidth）：那是「变小」，不是换形态'))
    if 'shellCollapse' not in index:
        bad += 1
        issues.append(('AE', 'FAIL', '外壳那条播放条没跟着收起（shellCollapse）：收起后会出现上下两条播放条'))

    # 两段时长：拖动零延迟，翻页与 Swiper 同长同曲线。
    # 不能只按「是否拖动中」判断——翻页动画是 Swiper 自己发的，手指可能还按着，
    # 那时拖动标志为真，指示器会停在原地干等动画跑完（录屏里就是连续静止 9 帧）。
    if not re.search(r"@StorageProp\('tabDur'\)", shell):
        bad += 1
        issues.append(('AE', 'FAIL', '底栏没订阅 tabDur：分不出「拖动零延迟」和「翻页补间」，只能一种时长走到底'))
    if not re.search(r'animateTo\(\{\s*duration:\s*this\.dur', shell):
        bad += 1
        issues.append(('AE', 'FAIL', '指示器没用 animateTo 按 tabDur 补间：属性动画同帧改时长不可靠，会卡住再硬跳'))
    if "'tabDur'" not in index:
        bad += 1
        issues.append(('AE', 'FAIL', 'Index 没广播 tabDur：底栏不知道这一段该走多长'))

    # 翻页动画一开始就要接管位置。等 onAnimationEnd 才挪，
    # 中间那段指示器完全静止，用户看到的就是「滑过去停一下」。
    if '.onAnimationStart(' not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', 'Swiper 没接 onAnimationStart：拿不到 targetIndex，只能等动画结束再补，中间必然停一下'))
    elif 'PAGE_ANIM_MS' not in (_func_body(index, 'beginRelease') or ''):
        bad += 1
        issues.append(('AE', 'FAIL', '接管时没广播补间时长（PAGE_ANIM_MS）：指示器会硬跳，不与页面同步'))

    # 指示器不许再用属性动画：同一帧里「时长从 0 变 300」和「位置变化」谁先应用不确定
    tb_start = shell.find('export struct TabBar')
    tb_end = shell.find('export struct MiniPlayer')
    tb = shell[tb_start:tb_end] if tb_start >= 0 and tb_end > tb_start else ''
    # 去掉注释行再查：注释里提到 .animation() 不算使用
    tb_code = '\n'.join([l for l in tb.split('\n')
                         if not l.lstrip().startswith('*') and not l.lstrip().startswith('//')])
    if re.search(r'\.animation\(', tb_code):
        bad += 1
        issues.append(('AE', 'FAIL', '指示器还在用属性动画 .animation()：同一帧改时长取哪次不确定，会卡住再硬跳'))

    # 松手后的兜底归位必须晚于 Swiper 自己的翻页动画。
    # 早于动画结束就归位，指示器会先被拉回旧页，动画跑完再跳新页——
    # 就是「快到目标页时回弹一下再过去」。
    body = _func_body(index, 'armSwipeIdle') or ''
    if 'PAGE_ANIM_MS' not in body:
        bad += 1
        issues.append(('AE', 'FAIL', '兜底归位没用 PAGE_ANIM_MS：定时器可能抢在翻页动画前面、把指示器拉回旧页'))
    if 'onAnimationEnd' not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', 'Swiper 没接 onAnimationEnd：指示器只能靠定时器猜动画何时结束'))

    # 手指是否还在屏幕上，必须以触摸事件为准。
    # onGestureSwipe 在松手后的收尾阶段还会回调，那时给的偏移量已经不是手指位置，
    # 照着走就会把指示器从新页拽回中间——用户看到的那下回弹。
    if '.onTouch(' not in tabs or 'TouchType.Down' not in tabs:
        bad += 1
        issues.append(('AE', 'FAIL', 'Swiper 没接 onTouch：分不出手指是否还在屏幕上，松手后的残余回调会拽回指示器'))
    elif not re.search(r'if \(!this\.dragging\)', tabs):
        bad += 1
        issues.append(('AE', 'FAIL', 'onGestureSwipe 没按 dragging 门控：松手后的残余位移照样生效'))

    # 异常位移必须整帧丢弃，不能「跟一半」。
    # 跟一半 = 主动往回退半格，看起来就是回弹。
    push = _func_body(index, 'pushSwipe') or ''
    if re.search(r'=\s*this\.swipeAt\s*\+\s*\(', push):
        bad += 1
        issues.append(('AE', 'FAIL', 'pushSwipe 对异常位移做了「跟一半」：那本身就是一次回退，会看出回弹'))
    if 'return;' not in push:
        bad += 1
        issues.append(('AE', 'FAIL', 'pushSwipe 没有丢弃异常位移的分支：基准切换的整格跳变会直接生效'))

    # ── 收起过渡的分层（AF）──
    # 两个形态同步淡入淡出，中间就是两团半透明糊在一起，看着是「换了一套 UI」。
    # 参考软件是分层的：文字先走、图标跟上、圆按钮和胶囊在后半段浮现。
    af = 0
    if not re.search(r'private\s+stage\s*\(\s*from:\s*number', shell):
        af += 1
        issues.append(('AF', 'FAIL', '底栏没有分段进度 stage()：各元素只能同步淡入淡出，中间是两团半透明'))
    else:
        uniq = set(re.findall(r'this\.stage\((\d+\.\d+),\s*(\d+\.\d+)\)', shell))
        if len(uniq) < 4:
            af += 1
            issues.append(('AF', 'FAIL',
                           f'分层只有 {len(uniq)} 段：文字/图标/圆按钮/胶囊至少要 4 段错开，否则是整块一起变'))
    # 栏体必须是「一条」：
    #   以前是宽度 100%→64%，只收右边——收起态那排其实铺满整宽，
    #   右边界先缩回去再弹出来，左右本就不对称；缩到一半时 62 高的旧底板
    #   和 52 高的新胶囊还能同时看见，两层圆角不同的轮廓叠成「胶囊套胶囊」。
    #   现在宽度不动、只把高度从 62 收到 52，圆角恒等于半高。
    if not re.search(r'private\s+barH\s*\(', shell):
        af += 1
        issues.append(('AF', 'FAIL', '栏体没有高度形变（缺 barH）：整条不会沉下去，只剩内容在换'))
    elif not re.search(r'\.height\(this\.barH\(\)\)', shell):
        af += 1
        issues.append(('AF', 'FAIL', 'barH 定义了但没挂到栏体上：高度仍是死的 62'))
    if not re.search(r'private\s+barR\s*\(', shell) or '.borderRadius(this.barR())' not in shell:
        af += 1
        issues.append(('AF', 'FAIL', '圆角没跟着高度走：收到一半会变成「圆角矩形」，不是胶囊'))
    if 'barWidthPct' in shell:
        af += 1
        issues.append(('AF', 'FAIL', '又在缩宽度（barWidthPct）：右边界先收后放，左右不对称，还会露出两层轮廓'))
    # 紧凑版不能再自带一层底板，否则又回到两条边线
    if not re.search(r"this\.inline \? '#00000000'|\.backgroundColor\('#00000000'\)", shell):
        af += 1
        issues.append(('AF', 'FAIL', '紧凑播放条还画着自己的底板：和栏体叠成两条圆角不一的边线'))
    # 高光必须垫在内容下面：盖在内容上会把封面冲成半透明灰
    if '.overlay(this.glassHighlight' in shell:
        af += 1
        issues.append(('AF', 'FAIL', '玻璃高光还用 overlay 盖着：白渐变铺过封面和文字，收起态封面发灰'))
    # 圆按钮要有放大浮现，不能只有淡入
    if not re.search(r'\.scale\(\{\s*[\s\S]{0,80}?x:\s*0\.\d+\s*\+', shell):
        af += 1
        issues.append(('AF', 'FAIL', '圆按钮只有淡入没有放大（scale 常量）：出现得像「颜色变深」，没有浮现感'))
    # 内容接力：旧图标的退场必须早于新内容登场，否则中间是一层双影
    m_icon = re.search(r'SymbolGlyph\([\s\S]{0,220}?\.opacity\(1 - this\.stage\((0\.\d+),\s*(0\.\d+)\)\)', shell)
    m_pill = re.search(r'MiniPlayer\(\{\s*inline:\s*true\s*\}\)[\s\S]{0,200}?\.opacity\(this\.stage\((0\.\d+),\s*(0\.\d+)\)\)',
                       shell)
    if not m_icon or not m_pill:
        af += 1
        issues.append(('AF', 'FAIL', '读不出图标/胶囊的接力段位：无法保证中间不出现双影'))
    elif float(m_icon.group(2)) > float(m_pill.group(1)):
        af += 1
        issues.append(('AF', 'FAIL',
                       f'图标退到 {m_icon.group(2)} 才干净、胶囊 {m_pill.group(1)} 就开始浮现：中间会看到图标压在封面上'))
    # 外壳那条悬浮播放条也要错开，不能直连 shellCollapse
    if 'barStage' not in index:
        af += 1
        issues.append(('AF', 'FAIL', '外壳播放条直连 shellCollapse：和底栏胶囊同步一进一出，中间会看到两条播放条'))
    if af == 0:
        issues.append(('AF', 'PASS', '收起过渡只有一条栏体（62→52 下沉、圆角恒半高），内容单向接力不重叠，高光垫底'))

    # ── 两种形态的命中测试（AG）──
    # 展开态和收起态在像素上完全重叠，收起态那层展开时是全透明的，
    # 但里面的封面 / 歌名 / 三个控制键照样能命中：点「发现」会掉进播放页，
    # 点「设置」会触发下一首或队列。hitTestBehavior(None) 只关自己、不关子树，
    # 必须整层 enabled 一起关。这条规则就是防它被改回去。
    ag = 0
    if not re.search(r'const\s+FORM_SWITCH', shell):
        ag += 1
        issues.append(('AG', 'FAIL', '没有形态分界常量：两层各写一个魔数，改了一边忘了另一边'))
    if shell.count('.enabled(this.collapse()') < 2:
        ag += 1
        issues.append(('AG', 'FAIL',
                       '两个形态层没有都用 enabled 互锁：只写 hitTestBehavior(None) 只关自己，'
                       '透明播放坞的子节点仍会抢走标签栏的点击'))
    if not re.search(r'private\s+live\s*\(\s*\)\s*:\s*boolean', shell):
        ag += 1
        issues.append(('AG', 'FAIL', 'MiniPlayer 没有 live() 守卫：紧凑版在展开态也能触发进播放页/切歌'))
    elif not re.search(r'private\s+enter\s*\(\s*\)\s*:\s*void\s*\{\s*\n\s*if\s*\(!this\.live\(\)\)', shell):
        ag += 1
        issues.append(('AG', 'FAIL', 'enter() 没走 live() 守卫：点标签会掉进播放页'))
    # 外壳那条播放条高度收到 0 后仍在树上，clip 不裁命中
    if not re.search(r'\.height\(58 \* \(1 - this\.barStage\([^)]*\)\)\)[\s\S]{0,240}?\.enabled\(', index):
        ag += 1
        issues.append(('AG', 'FAIL', '外壳播放条收到 0 高后没禁用：底栏上方留一条看不见的进播放页热区'))
    if ag == 0:
        issues.append(('AG', 'PASS', '两种形态按 FORM_SWITCH 互锁 enabled，透明层与 0 高层的子节点都不再抢点击'))

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

    # ── 底栏的立体玻璃（AI）──
    # 单色 rgba 平涂 + 一圈同色 0.8 描边是最省事的画法，但它是"磨砂塑料"：
    # 每个像素都一样，眼睛拿不到厚度。这里卡住四件事，少一件就退回塑料板。
    ai = 0
    consts = next((s for f, s in src.items() if f.endswith('common/Constants.ets')), '')
    if not re.search(r'export function glassSurface\s*\(', consts):
        ai += 1
        issues.append(('AI', 'FAIL', '缺 glassSurface：表面回到单色 rgba，又变成一块平涂的雾'))
    else:
        # v2.52 墨栈：去光化后表面是「中性实色」，不再叠多段 rgba 青绿渐变。
        # 断言从「必须有多段受光渐变」等价改写为「必须是同色两段实色、不含 rgba 染色」，
        # 防止以后又把发光玻璃搬回来 —— 守断言跟着设计走，而非让设计迁就断言。
        surface = re.search(r'export function glassSurface[\s\S]*?\n}', consts)
        body = surface.group(0) if surface else ''
        if 'return [[c, 0], [c, 1]];' not in body or 'rgba(' in body:
            ai += 1
            issues.append(('AI', 'FAIL', 'glassSurface 没收敛成中性同色实色：墨栈表面不该再有多段 rgba 渐变'))
    if not re.search(r'export function glassDepth\s*\(', consts):
        ai += 1
        issues.append(('AI', 'FAIL', '缺 glassDepth：下沿没有聚光，栏体看着像薄薄一张纸'))
    # v2.52 墨栈：改 1vp 等宽发丝线，不再靠「下比上厚」伪造玻璃厚度
    if not re.search(r"top:\s*1,\s*right:\s*1,\s*bottom:\s*1,\s*left:\s*1", consts):
        ai += 1
        issues.append(('AI', 'FAIL', 'glassEdgeWidth 不是 1vp 等宽发丝线：墨栈不靠不等厚描边表达厚度'))
    # 底沿那道内高光必须在
    if '底沿内高光' not in shell:
        ai += 1
        issues.append(('AI', 'FAIL', '缺底沿内高光：玻璃下沿没有反射光，边缘显得是「描上去的线」'))
    # 聚光带必须局限在下部，铺满整条就把整块刷白了
    deps = re.findall(r'@Builder\s*\n\s*depthLayer\s*\(\)\s*\{[\s\S]{0,300}?\}', shell)
    if len(deps) < 2:
        ai += 1
        issues.append(('AI', 'FAIL', f'聚光层只挂在 {len(deps)} 处：标签栏和播放条是两块玻璃，都要有'))
    elif any(not re.search(r"height\('2[0-9]%'\)", d) for d in deps):
        ai += 1
        issues.append(('AI', 'FAIL', '聚光带没有限制在底部（应 20%~29% 高）：铺满会把整条刷成奶白'))
    # 定义了 @Builder 不等于挂上了 —— 少挂一处，那块玻璃就没有厚度
    if len(re.findall(r'this\.depthLayer\(\)', shell)) < len(deps):
        ai += 1
        issues.append(('AI', 'FAIL', '聚光层定义了但没挂全：有玻璃还是平的'))
    # v2.52 墨栈：中性紧投影，offsetY 收到 2/4，不做离地浮起感
    if 'offsetY: isDark ? 4 : 2' not in consts:
        ai += 1
        issues.append(('AI', 'FAIL', 'glassShadow 不是中性紧投影（offsetY 2/4）：墨栈不要离地浮起光晕'))
    # 选中指示器要有自己的渐变+亮边，不能还是平涂
    pill_block = re.search(r'\.borderRadius\(RADIUS\.pill\)([\s\S]{0,2200}?)\.position\(\{ x: this\.pillX', shell)
    if not pill_block:
        ai += 1
        issues.append(('AI', 'FAIL', '找不到选中指示器：无法校验它的表面'))
    elif 'linearGradient' not in pill_block.group(1):
        ai += 1
        issues.append(('AI', 'FAIL', '选中指示器还是平涂：和栏体糊成一片，看不出浮在栏面上'))
    if ai == 0:
        issues.append(('AI', 'PASS',
                       '底栏两层都是「渐变表面 + 上薄下厚四边 + 底沿内高光 + 向下投影」，选中片独立成一块小玻璃'))

    # ── 整页液态玻璃（AJ）──
    # 上一版只改了底栏两条，设置页 6 张卡、首页搜索框 + 快捷卡全是纯白，
    # 用户看到「整页没变化」。这一组卡住「覆盖到每一张卡」和「渐变真能画出来」。
    aj = 0
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
    # backgroundBlurStyle 和 linearGradient 抢同一个背景，是「改了没变化」的最大嫌疑
    shell_code = '\n'.join(ln for ln in shell.split('\n')
                           if not ln.lstrip().startswith('//') and not ln.lstrip().startswith('*'))
    if '.backgroundBlurStyle(' in shell_code:
        aj += 1
        issues.append(('AJ', 'FAIL', '底栏仍叠 backgroundBlurStyle：模糊材质可能整层盖掉线性渐变'))
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
    for name in ('DownloadsPage', 'SheetDetailPage', 'PlayerPage',
                 'SearchPage', 'ArtistPage', 'SourcesPage', 'RankBoardPage'):
        pages[name] = next((s for f, s in src.items()
                           if f.endswith('ui/pages/' + name + '.ets')), '')
    # 真正铺了玻璃的页面，各自至少这么多处 backgroundColor(glassCardBase(this.isDark))
    # v2.55：下载页清掉不可达的多选状态机后少了「全选 / 删除」两枚玻璃胶囊，
    # 玻璃底由 5 处降为 4 处 —— 降的是已删控件，不是白卡回潮。
    need = {'DownloadsPage': 4, 'SheetDetailPage': 4, 'PlayerPage': 5,
            'SearchPage': 4, 'ArtistPage': 1, 'SourcesPage': 6}
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
    if 'withAlpha(this.p().danger' not in pages['DownloadsPage'] + pages['SheetDetailPage']:
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
    if 'backgroundColor(this.p().danger)' not in downloads or "#FFFFFFFF" not in downloads:
        am += 1
        issues.append(('AM', 'FAIL', '下载页危险色语义被抹掉：左滑删除看不出是破坏性操作'))
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

    # 3) 下载管理：只留清理动作
    if "Text('清除')" not in downloads:
        aq += 1
        issues.append(('AQ', 'FAIL', '「清空已完成」没改成「清除」'))
    if "Text('清空已完成')" in downloads:
        aq += 1
        issues.append(('AQ', 'FAIL', '还残留「清空已完成」旧文案'))
    if "Text('选择')" in downloads:
        aq += 1
        issues.append(('AQ', 'FAIL', '下载管理还留着「选择」入口'))
    if 'clearDone()' not in downloads or 'clearFailed()' not in downloads:
        aq += 1
        issues.append(('AQ', 'FAIL', '清理动作没接上 downloads.clearDone / clearFailed'))

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
    # 底层 PlayStats 与播放器埋点保留（见 AT/AU），只是不再参与任何界面。
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
                       '统计底层 PlayStats 保留但不再参与界面'))

    # ================= AT：真实收听统计层 =================
    at = 0
    stats = next((s for f, s in src.items() if f.endswith('core/PlayStats.ets')), '')
    player = next((s for f, s in src.items() if f.endswith('core/Player.ets')), '')
    app = next((s for f, s in src.items() if f.endswith('core/App.ets')), '')
    consts = next((s for f, s in src.items() if f.endswith('common/Constants.ets')), '')
    if not stats:
        at += 1
        issues.append(('AT', 'FAIL', '缺少 PlayStats.ets：没有真实收听统计层'))
    else:
        for kw in ('onProgress(timeMs: number, playing: boolean, song: SongInfo)',
                   'delta > DELTA_LIMIT', 'delta <= 0', 'KEEP_HOURS',
                   'MINUTES_IN_RANGE_FIXME' if False else 'minutesInRange(range: number)',
                   'hourBuckets(range: number)', 'trendPoints(range: number)',
                   'topArtist(): string', 'newSongsInRange(range: number)',
                   'Library.get().getHistory()', 'Store.get().put(PrefKeys.PLAY_STATS'):
            if kw not in stats:
                at += 1
                issues.append(('AT', 'FAIL', '统计层缺关键实现：' + kw))
        if 'Math.random' in stats:
            at += 1
            issues.append(('AT', 'FAIL', '统计层出现 Math.random：数据不是真实测量'))
        if 'setInterval' in stats:
            at += 1
            issues.append(('AT', 'FAIL', '统计层不该自己起定时器：累计必须跟着播放回调'))
    if 'PlayStats.get().onSongStart(song)' not in player:
        at += 1
        issues.append(('AT', 'FAIL', 'Player 切歌没通知统计层：新歌判定会失效'))
    if 'PlayStats.get().onProgress(time, this.playing, this.current)' not in player:
        at += 1
        issues.append(('AT', 'FAIL', 'Player 的 timeUpdate 没接真实进度累计'))
    if 'PlayStats.get().flush()' not in player:
        at += 1
        issues.append(('AT', 'FAIL', '暂停时没落盘：最多可能丢 20 秒统计'))
    if "static readonly PLAY_STATS" not in consts:
        at += 1
        issues.append(('AT', 'FAIL', 'Constants 没定义 PLAY_STATS 持久化键'))
    # init 顺序：Store → Library → PlayStats → Player
    i_store = app.find('await Store.get().init(context)')
    i_lib = app.find('this.library.init()')
    i_stats = app.find('PlayStats.get().init()')
    i_player = app.find('this.player.init(context)')
    if not (0 <= i_store < i_lib < i_stats < i_player):
        at += 1
        issues.append(('AT', 'FAIL', 'PlayStats.init 顺序不对：必须在 Library 之后、Player 之前'))
    if at == 0:
        issues.append(('AT', 'PASS',
                       '真实统计链路闭合：timeUpdate 进度差累计（过滤 seek 跳变）、本地小时桶持久化、'
                       '暂停立刻落盘、31 天小时桶 + 400 天日归档双窗口裁剪、旧播放历史并入已知歌曲'))

    # ================= AU：月·回响数据地基（按日事件日志） =================
    au = 0
    stats_src = next((x for f, x in src.items() if f.endswith('core/PlayStats.ets')), '')
    player_src = next((x for f, x in src.items() if f.endswith('core/Player.ets')), '')
    if not stats_src:
        au += 1
        issues.append(('AU', 'FAIL', '缺少 PlayStats.ets'))
    else:
        for kw in ('interface DayStat', 'interface SongMeta', 'interface SongPlay',
                   'KEEP_REPORT_DAYS: number = 400', 'hourMs: Array<[number, number]>',
                   'onCompleted(song: SongInfo)', 'reportOf(year: number, month: number)',
                   'availableMonths()', 'this.monthDayStart(year, month + 1)',
                   'd.days instanceof Array ? d.days : []',
                   'Math.min(100, Math.round(finished / plays * 100))'):
            if kw not in stats_src:
                au += 1
                issues.append(('AU', 'FAIL', '报告数据地基缺关键实现：' + kw))
        # 看板老接口必须还在，别为了做报告把驿站弄坏
        for kw in ('minutesInRange(range: number)', 'trendPoints(range: number)',
                   'hourBuckets(range: number)', 'topArtist(): string',
                   'newSongsInRange(range: number)'):
            if kw not in stats_src:
                au += 1
                issues.append(('AU', 'FAIL', '做报告时弄丢了看板接口：' + kw))
        if 'Math.random' in stats_src or 'setInterval' in stats_src:
            au += 1
            issues.append(('AU', 'FAIL', '统计层出现随机函数或定时器：数据不是真实测量'))
    if 'PlayStats.get().onCompleted(this.current)' not in player_src:
        au += 1
        issues.append(('AU', 'FAIL', 'Player 的 completed 回调没记完播：完播率会恒为 0'))
    if au == 0:
        issues.append(('AU', 'PASS',
                       '按日播放事件日志保留 400 天（跨月可回看），切歌记次数 / 进度记时长 / '
                       'completed 记完播，旧看板接口与 31 天小时桶原样保留'))

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
    if (not opt or 'if (!this.smartHunt)' not in opt or '} else {' not in opt or
            'this.smartHuntHint()' not in opt or
            opt.count('this.preferOnlyRow()') != 1 or
            opt.count('this.downgradeRow()') != 1 or
            opt.count('this.fallbackRow()') != 1):
        bad += 1
        issues.append(('AX', 'FAIL', '音源页没有按懒人模式条件隐藏 3 项旧取链配置（关闭时须全部恢复）'))
    if '已隐藏 3 项旧取链配置' not in page or '仍作用于歌词' not in page:
        bad += 1
        issues.append(('AX', 'FAIL', '懒人模式隐藏项没有说明，或没讲清「只用首选音源」仍作用于歌词'))
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
    # 汽水：说明要写清楚为什么不支持，别让用户反复试。
    # v2.72：导入面板搬到收藏页，这段说明也随之迁移，检查对象换成收藏页。
    if '汽水音乐等平台暂不支持' not in fav or '扫码登录' not in fav:
        bad += 1
        issues.append(('AZ', 'FAIL', '收藏页导入面板没说明汽水等平台为何不支持'))
    if bad == 0:
        issues.append(('AZ', 'PASS',
                       '歌单收藏改为长按选中该张并进入多选（顶部「选择」已移除、批量删除保留），'
                       '播放剩余 60 秒预取下一首且同 key 在途去重，导入面板写明汽水等平台不支持的原因'))


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
    if "DownloadTaskRow({ taskId: task.id })" not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', 'ListItem 没挂 DownloadTaskRow（或没传稳定 taskId）'))
    if "@StorageProp('downloadVersion') dlVersion" not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '行组件没订阅 downloadVersion，进度广播不会触发重绘'))
    if 'this.dlVersion + 1' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '行组件没在渲染路径读 dlVersion，订阅可能被编译器优化掉'))
    if 'private task(): DownloadTask' not in dl or 'App.get().downloads.list()' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '行组件没按 id 从 Downloader 实时数组取任务'))
    # ④ 页面层不再做「换引用 / 快照」这类无效 hack，也不再把进度塞进 @Builder
    for kw, msg in (
        ('private taskSig(', '还留着上一版换引用 hack 的 taskSig'),
        ('private copyTask(', '还留着上一版换引用 hack 的 copyTask'),
        ('next.push(this.copyTask(t))', '还在生成任务快照（真机无效）'),
    ):
        if kw in dl:
            bad += 1
            issues.append(('BC', 'FAIL', '下载页 ' + msg))
    # ⑤ 左滑删除入口本身不能被改没，且不依赖旧 task 快照判状态
    if '.swipeAction(' not in dl or 'SwipeEdgeEffect.Spring' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '左滑删除入口 / 弹性边缘效果被移除'))
    if 'this.swipeDelete(task.id)' not in dl or 'private stillActive(id: string)' not in dl:
        bad += 1
        issues.append(('BC', 'FAIL', '左滑删除没按 id 取实时状态，删下载中任务文案会冻结'))
    if bad == 0:
        issues.append(('BC', 'PASS',
                       '下载行抽成独立组件 DownloadTaskRow：key 只认 id 不回弹，'
                       '行组件自订阅 downloadVersion 并按 id 实时取数，进度实时且左滑展开态保持'))


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
        ('外观页', appearance, ('跟随系统', '浅色', '深色', '字号', '显示翻译歌词',
                                '光感四档已取消', '知道了')),
        ('数据管理页', data, ('备份我的数据', '从备份恢复', '音源脚本（含脚本正文')),
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

    # v2.74：滚动速度统一降到 step 2；留着任一处 step 4 就是「改了 SongRow 忘了迷你条」
    if all_ets.count('step: 2, fromStart: true') != 7 or 'step: 4' in all_ets:
        be += 1
        issues.append(('BE', 'FAIL', '跑马灯速度没统一到 step: 2（7 处）：仍有旧速度或漏改组件'))

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
                    ('音源脚本（含脚本正文', '缺备份范围说明'),
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
                    ("'每日推荐'", '每日推荐板块标题丢了'),
                    ('左右滑动换组', '没提示用户可左右滑动换组')):
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
    if '汽水音乐等平台暂不支持' not in fav:
        bt += 1
        issues.append(('BT', 'FAIL', '收藏页导入面板丢了汽水不支持说明'))

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
      ④ v2.56 光感迁移提示（lightNotice / 光感四档已取消）是独立功能，保留不误删；
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
        # ④ lightNotice 提示条（v2.56 独立功能）保留
        if '@State lightNotice: boolean = false;' not in appearance or \
                '光感四档已取消' not in appearance:
            ca += 1
            issues.append(('CA', 'FAIL', 'v2.56 光感迁移提示条被误删（它是独立功能，不该随青绿引擎一起去掉）'))

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
                       'v2.56 光感迁移提示条保留，品牌主色不受牵连'))


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
                 'v4_qq_', 'v4_kg_', 'fcg_qm_order_diss', 'gateway.kugou.com',
                 'login-user.kugou.com', 'ptqrshow', 'qrcode_img')
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
                    ('stripId3', '没剥离旧 ID3（重复写入会叠标签）')):
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
    for kw, msg in (('AudioTag.embed(task.path, task.format, task.song,', '落盘后没调用内嵌'),
                    ('embedLyricLater(', '缺歌词异步补齐'),
                    ('LyricRepo.get().get(song)', '没从歌词仓库取词'),
                    ('toLrcText(', '缺 LyricDoc→LRC 还原'),
                    ('不影响下载', '标签失败没兜住（会连累下载结果）')):
        if kw not in dl:
            ce += 1
            issues.append(('CE', 'FAIL', 'Downloader ' + msg))
    # 顺序：embed 必须在 copyToTarget 之后、标记 done 之前
    copy_at = dl.find('this.copyToTarget(tempPath, fileName)')
    embed_at = dl.find('AudioTag.embed(task.path, task.format, task.song,')
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
               check_smart_hunt, check_longpress_preload, check_fav_layout,
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
               check_download_audio_tags):
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
