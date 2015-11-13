//
//  ExampleCameraViewController.swift
//  LLSimpleCamera
//
//  Created by Brett Trimble on 11/9/15.
//  Copyright © 2015 Ömer Faruk Gül. All rights reserved.
//

import UIKit
import LLSimpleCamera

class ExampleCameraViewController: LLCameraViewController {

    override func viewDidLoad() {
        
        self._renderer = RippleOpenGLRenderer()
        super.viewDidLoad()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    
//    override func glkView(view: GLKView, drawInRect rect: CGRect) {
//        let renderer = self._renderer as! RippleOpenGLRenderer
//        let _ripple = renderer.ripple
//        if _ripple == nil {
//            return
//        }
//        let context = EAGLContext.currentContext()
//        glBufferData(GLenum(GL_ARRAY_BUFFER), GLsizeiptr(_ripple.getVertexSize()), _ripple.getTexCoords(), GLenum(GL_DYNAMIC_DRAW))
//        glDrawElements(GLenum(GL_TRIANGLE_STRIP), GLsizei(_ripple.getIndexCount()), GLenum(GL_UNSIGNED_SHORT), nil)
//            
//        renderer.cleanUpTextures()
//
//    }
    
    // MARK - Touch handling methods
    
    func myTouch(touches: Set<UITouch>, withEvent event: UIEvent?) {
        if let renderer = _renderer as? RippleOpenGLRenderer {
            for touch in touches {
                let location = touch.locationInView(touch.view)
                (self._renderer as! RippleOpenGLRenderer).initiateRippleAtLocation(location)
            }
        } //else {
//            self._renderer = RippleOpenGLRenderer()
//        }
        
//        if let _ = _renderer as? RippleOpenGLRenderer {
//            self._renderer = RosyWriterOpenGLRenderer()
//        } else if let _ = _renderer as? DefaultRenderer {
//            self._renderer = RippleOpenGLRenderer()
//        } else {
//            self._renderer = DefaultRenderer()
//        }
    }
    
    
    override func touchesBegan(touches: Set<UITouch>, withEvent event: UIEvent?) {
        super.touchesBegan(touches, withEvent: event)
        myTouch(touches, withEvent: event)
    }
    
    
    override func touchesMoved(touches: Set<UITouch>, withEvent event: UIEvent?) {
        super.touchesMoved(touches, withEvent: event)
        myTouch(touches, withEvent: event)
    }
    

    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

}
